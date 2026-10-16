## NYX's private, user-level data: where it lives and the JSON state file.
##
## Layout of the data directory:
##
##   state.json   what NYX manages, per project (never edited by hand)
##   skills/      git clone of the skills repository; the one canonical copy
##                of every skill, which projects link to (or copy from)

import std/[syncio, os, dirs, files, json, envvars, times]

const
  SchemaVersion* = 1
  DefaultCheckEvery* = 30 * 24 * 60 * 60   ## seconds between lazy update checks

type
  InstallMode* = enum
    Link, Copy

  Install* = object
    ## One skill placed into one agent skill directory by NYX.
    path*: string        ## absolute destination, created by NYX
    skill*: string
    mode*: InstallMode
    source*: string      ## what a link points to / a copy was taken from
    files*: seq[string]  ## Copy only: files NYX wrote, relative to `path`

  Project* = object
    root*: string           ## canonical absolute project root; the key
    targets*: seq[string]   ## target ids
    skills*: seq[string]
    installs*: seq[Install]
    dirs*: seq[string]      ## directories NYX created, outermost first

  State* = object
    version*: int
    lastCheck*: int         ## unix seconds of the last update check, 0 = never
    checkEvery*: int        ## seconds
    repoRev*: string        ## last skills commit applied to recorded installs
    projects*: seq[Project]

proc newState*(): State =
  State(version: SchemaVersion, checkEvery: DefaultCheckEvery)

proc dataDir*(): string =
  ## `NYX_HOME` overrides the platform data directory.
  result = getEnv("NYX_HOME")
  if result.len == 0:
    result = getDataDir() / "nyx"

proc statePath*(data: string): string = data / "state.json"
proc skillsDir*(data: string): string = data / "skills"

proc now*(): int = int(getTime().toUnix)

proc isStale*(s: State; t: int): bool =
  ## True when the last update check is older than the check interval.
  t - s.lastCheck >= s.checkEvery

proc find*(s: State; root: string): int =
  result = -1
  for i in 0 ..< s.projects.len:
    if s.projects[i].root == root: return i

# --- project root ---------------------------------------------------------

proc projectRoot*(start: string): string {.raises.} =
  ## Canonical root for `start`: the nearest enclosing directory holding a
  ## `.git` entry (a directory, or a file for worktrees), else `start`.
  ## Symlinks are resolved so one project has one key.
  let here = expandFilename(start)
  var dir = here
  while true:
    let git = dir / ".git"
    if dirExists(git) or fileExists(git): return dir
    let up = parentDir(dir)
    if up.len == 0 or up == dir: break
    dir = up
  result = here

# --- JSON -----------------------------------------------------------------

proc schemaVersion(t: var JsonTree): int64 =
  ## The document's `version`, or -1, checked before `fromJson` reads the rest.
  result = -1
  if kind(t.root) == JObject:
    for k, v in pairs(t.root):
      if k == "version": return getInt(v, -1)

proc parseState*(text: string; ok: var bool): State =
  ## Fields are read as `toJson` writes them: in declaration order, all
  ## present. `ok` is false when `text` is not a NYX state document of the
  ## current schema version.
  result = newState()
  var t = parseJson(text)
  ok = not hasError(t) and schemaVersion(t) == SchemaVersion
  if not ok: return
  result = fromJson(t, State)
  if result.checkEvery <= 0:
    result.checkEvery = DefaultCheckEvery

proc loadState*(data: string; corrupt: var bool): State =
  ## A missing file is a fresh state. An unreadable one is set aside as
  ## `state.json.bad` (never silently overwritten) and also starts fresh.
  corrupt = false
  let file = statePath(data)
  if not fileExists(file): return newState()
  var text = ""
  try:
    text = readFile(file)
  except:
    corrupt = true
    return newState()
  var ok = false
  result = parseState(text, ok)
  if not ok:
    corrupt = true
    try:
      moveFile(path(file), path(file & ".bad"))
    except:
      discard

proc saveState*(data: string; s: State) {.raises.} =
  ## Write to a temporary file, then rename over the old state, so an
  ## interrupted write never leaves a truncated state.json behind.
  createDir(path(data))
  var t = toJson(s)
  let file = statePath(data)
  let tmp = file & ".tmp"
  writeFile(tmp, $t)
  moveFile(path(tmp), path(file))
