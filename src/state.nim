## NYX's private, user-level data: where it lives and the JSON state file.
##
## Layout of the data directory:
##
##   state.json   what NYX manages, per project (never edited by hand)
##   skills/      git clone of the skills repository; the one canonical copy
##                of every skill, which projects link to (or copy from)

import std/[appdirs, paths, syncio, os, dirs, files, json, envvars, times, opt]

const
  SchemaVersion* = 1
  DefaultCheckEvery* = 15 * 24 * 60 * 60   ## seconds between lazy update checks

type
  InstallMode* = enum
    Link, Copy

  Install* = object
    ## One skill placed into one agent skill directory by NYX.
    path*: Path  ## absolute destination, created by NYX
    skill*: string
    mode*: InstallMode
    source*: Path  ## what a link points to / a copy was taken from
    files*: seq[Path]  ## Copy only: files NYX wrote, relative to `path`

  Project* = object
    root*: Path  ## canonical absolute project root; the key; empty when `global`
    global*: bool  ## the user's own skill directories, not a project
    targets*: seq[string]   ## target ids
    skills*: seq[string]
    installs*: seq[Install]
    dirs*: seq[Path]  ## directories NYX created, outermost first

  State* = object
    version*: int
    lastCheck*: int         ## unix seconds of the last update check, 0 = never
    checkEvery*: int        ## seconds
    repoRev*: string        ## last skills commit applied to recorded installs
    projects*: seq[Project]

proc newState*(): State =
  State(version: SchemaVersion, checkEvery: DefaultCheckEvery)

proc dataDir*(): Path =
  ## `NYX_HOME` overrides the platform data directory.
  result = path(getEnv("NYX_HOME"))
  if result == path(""):
    result = appdirs.getDataDir() / path("nyx")

proc statePath*(data: Path): Path = data / path("state.json")
proc skillsDir*(data: Path): Path = data / path("skills")

proc now*(): int = int(getTime().toUnix)

proc isStale*(s: State; t: int): bool =
  ## True when the last update check is older than the check interval.
  t - s.lastCheck >= s.checkEvery

proc find*(s: State; root: Path): int =
  ## Match project keys using normalized paths and the platform's case rules.
  result = -1
  for i in 0 ..< s.projects.len:
    if not s.projects[i].global and s.projects[i].root == root: return i

proc findGlobal*(s: State): int =
  ## The user-scope entry, or -1.
  result = -1
  for i in 0 ..< s.projects.len:
    if s.projects[i].global: return i

# --- project root ---------------------------------------------------------

proc projectRoot*(start: Path): Path {.raises.} =
  ## Canonical root for `start`: the nearest enclosing directory holding a
  ## `.git` entry (a directory, or a file for worktrees), else `start`.
  ## Symlinks are resolved so one project has one key.
  let here = path(expandFilename($start))
  var dir = here
  while true:
    let git = dir / path(".git")
    if dirExists($git) or fileExists($git): return dir
    let up = parentDir(dir)
    if up == path("") or up == dir: break
    dir = up
  result = here

# --- JSON -----------------------------------------------------------------

## Keep paths as JSON strings so schema version 1 remains compatible.
proc toJson(t: var JsonTree; p: Path; opts: JsonOptions) =
  toJson(t, $p, opts)

proc fromJson(c: var JsonNode; t: typedesc[Path]; opts: JsonOptions): Path =
  path(fromJson(c, string, opts))

proc schemaVersion(t: var JsonTree): int64 =
  ## The document's `version`, or -1, checked before `fromJson` reads the rest.
  result = -1
  if kind(t.root) == JObject:
    for k, v in pairs(t.root):
      if k == "version": return getInt(v, -1)

proc parseState*(text: string): Opt[State] =
  ## Fields are read as `toJson` writes them: in declaration order, all
  ## present. `none` means `text` is not a NYX state document of the current
  ## schema version.
  var t = parseJson(text)
  if hasError(t) or schemaVersion(t) != SchemaVersion: return none[State]()
  var s = fromJson(t, State)
  if s.checkEvery <= 0:
    s.checkEvery = DefaultCheckEvery
  result = some(s)

proc loadState*(data: Path): tuple[state: State, corrupt: bool] =
  ## A missing file is a fresh state. An unreadable one is set aside as
  ## `state.json.bad` (never silently overwritten) and also starts fresh;
  ## `corrupt` reports that it had to be discarded.
  result = (state: newState(), corrupt: false)
  let file = statePath(data)
  if not fileExists($file): return
  var text = ""
  try:
    text = readFile($file)
  except:
    result.corrupt = true
    return
  let parsed = parseState(text)
  if parsed.isNone:
    result.corrupt = true
    try:
      moveFile(file, data / path("state.json.bad"))
    except:
      discard
  else:
    result.state = parsed.get(result.state)

proc saveState*(data: Path; s: State) {.raises.} =
  ## Write to a temporary file, then rename over the old state, so an
  ## interrupted write never leaves a truncated state.json behind.
  createDir(data)
  var t = toJson(s)
  let file = statePath(data)
  let tmp = data / path("state.json.tmp")
  writeFile($tmp, $t)
  moveFile(tmp, file)
