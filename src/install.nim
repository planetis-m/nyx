## Placing skills into a project's agent skill directories and taking them
## out again.
##
## Safety rules:
## * a destination that already exists and is not recorded in state is a
##   collision: it is reported and never touched;
## * removal only ever acts on recorded installs, and only while they still
##   look like what NYX made (the same link, or a real directory for a copy);
## * a copy is removed file by file from its recorded list, and directories
##   only go away once empty, so files a user added survive.

import std/[paths, symlinks, os, dirs, files]
import state

type
  Report* = object
    placed*: seq[Path]  ## destinations created
    removed*: seq[Path]  ## destinations removed
    collisions*: seq[Path]  ## existing, not NYX's: left alone
    kept*: seq[Path]  ## NYX's, but changed by the user: left alone
    failed*: seq[Path]

proc taken*(p: Path): bool =
  ## Anything at `p`, including a dangling symlink.
  symlinkExists(p) or fileExists($p) or dirExists($p)

proc intact*(inst: Install): bool =
  ## Does `inst` still have NYX's link target, or a real directory for a copy?
  case inst.mode
  of Link:
    result = false
    if symlinkExists(inst.path):
      try:
        result = expandSymlink(inst.path) == inst.source
      except:
        result = false
  of Copy:
    result = dirExists($inst.path) and not symlinkExists(inst.path)

# --- filesystem helpers -----------------------------------------------------

proc ensureDir(dir: Path; p: var Project) {.raises.} =
  ## Create `dir` and its missing parents, recording each one NYX made.
  if dirExists($dir): return
  let up = parentDir(dir)
  if up != path("") and up != dir: ensureDir(up, p)
  createDir(dir)
  p.dirs.add dir

proc linked(dir, file: Path): bool =
  ## Check only within the owned copy; configured directories above it may
  ## legitimately be links. A replaced parent must never redirect our work.
  var rel = file
  while rel != path(""):
    if symlinkExists(dir / rel): return true
    rel = parentDir(rel)
  result = false

proc copyTree(src, dest: Path; files: var seq[Path]) {.raises.} =
  ## Copy regular files and directories; symlinks inside a skill are skipped
  ## (neither yielded nor followed). A directory is yielded before its
  ## contents, so creating it here also keeps empty ones.
  for r in walkDirRec(src, yieldFilter = {pcFile, pcDir},
                      followFilter = {pcDir}, relative = true):
    if linked(dest, r): continue
    if dirExists($(src / r)):
      createDir(dest / r)
    else:
      let existed = taken(dest / r)
      var copied = false
      try:
        copyFileWithPermissions(src / r, dest / r)
        copied = true
      finally:
        # A failed copy can still have created a partial destination file.
        if (copied or not existed) and fileExists($(dest / r)) and r notin files:
          files.add r

proc removeEmptyDirs(dir: Path) =
  ## Remove `dir` and its subdirectories bottom-up, but only the empty ones.
  try:
    for kind, p in walkDir(dir):
      if kind == pcDir: removeEmptyDirs(p)
  except:
    discard
  discard tryRemoveFinalDir(dir)

proc removeOurFile(dir, file: Path) =
  if not linked(dir, file) and fileExists($(dir / file)):
    discard tryRemoveFile(dir / file)

proc pruneDirs(p: var Project) =
  ## Drop directories NYX created that are now empty, innermost first.
  var left: seq[Path] = @[]
  for i in countdown(p.dirs.high, 0):
    let d = p.dirs[i]
    if dirExists($d) and not symlinkExists(d) and tryRemoveFinalDir(d) != Success:
      left.add d
  p.dirs = @[]
  for i in countdown(left.high, 0): p.dirs.add left[i]

# --- install / uninstall ------------------------------------------------------

proc place(p: var Project; skill: string; src, dest: Path; copy: bool) {.raises.} =
  ## Link `dest` to `src`, falling back to a copy where links are not
  ## available (e.g. Windows without developer mode).
  ensureDir(parentDir(dest), p)
  var inst = Install(path: dest, skill: skill, mode: Link, source: src)
  if not copy:
    try:
      createSymlink(src, dest)
      p.installs.add inst
      return
    except:
      discard
  inst.mode = Copy
  createDir(dest)
  try:
    copyTree(src, dest, inst.files)
  finally:
    p.installs.add inst   # recorded even if partial, so remove can clean up

proc unplace*(inst: Install): bool =
  ## Remove one install. False when it was changed by the user and is left.
  if not taken(inst.path): return true
  if not intact(inst): return false
  case inst.mode
  of Link:
    if tryRemoveFile(inst.path) != Success:
      discard tryRemoveFinalDir(inst.path)   # directory links on Windows
  of Copy:
    for f in inst.files: removeOurFile(inst.path, f)
    removeEmptyDirs(inst.path)
  result = not taken(inst.path)

proc resync*(inst: var Install) {.raises.} =
  ## Bring a copy up to date with its source. Links need nothing. A skill
  ## that vanished upstream keeps its last copy.
  if inst.mode != Copy or not intact(inst) or not dirExists($inst.source): return
  var files: seq[Path] = @[]
  try:
    copyTree(inst.source, inst.path, files)
  finally:
    # Retain old ownership and any new partial work even if copying raises.
    for f in files:
      if f notin inst.files: inst.files.add f
  for f in inst.files:
    if f notin files: removeOurFile(inst.path, f)
  inst.files = files

proc sync*(p: var Project; store: Path; dirs: seq[Path]; skills: seq[string];
           copy = false): Report =
  ## Make the project hold exactly `skills` in each of `dirs` (relative to
  ## `p.root`, or absolute for a global project), linking from `store`.
  ## `copy` forces copies.
  result = Report()
  var bases: seq[Path] = @[]
  for d in dirs: bases.add(if p.global: d else: p.root / d)
  var want: seq[Path] = @[]
  for b in bases:
    for s in skills: want.add b / path(s)

  var keep: seq[Install] = @[]
  for inst in p.installs:
    if inst.path in want:
      # Missing or replaced installs are no longer ours.
      if intact(inst): keep.add inst
    elif unplace(inst):
      result.removed.add inst.path
    else:
      result.kept.add inst.path
  p.installs = keep

  for b in bases:
    for s in skills:
      let dest = b / path(s)
      var have = false
      for inst in p.installs:
        if inst.path == dest:
          have = true
          break
      if not have:
        if taken(dest):
          result.collisions.add dest
        elif not dirExists($(store / path(s))):
          result.failed.add dest
        else:
          try:
            place(p, s, store / path(s), dest, copy)
            result.placed.add dest
          except:
            result.failed.add dest
  pruneDirs(p)

proc removeAll*(p: var Project): Report =
  ## Undo everything NYX did in this project.
  result = Report()
  for inst in p.installs:
    if unplace(inst): result.removed.add inst.path
    else: result.kept.add inst.path
  p.installs = @[]
  pruneDirs(p)

proc missing*(p: Project): int =
  ## Installs that are no longer what NYX put there.
  result = 0
  for inst in p.installs:
    if not intact(inst): inc result
