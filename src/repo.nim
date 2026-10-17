## The skills repository, fetched with the `git` executable. Access comes
## from the user's own GitHub authentication; NYX never asks for credentials,
## and git is told not to prompt for them either.
##
## This is the only module that knows skills come from git.

import std/[paths, strutils, os, osproc, streams, envvars, strtabs]

const DefaultRepo* = "https://github.com/verified-nim/skills"

type GitResult* = enum
  Done, NoGit, NoAccess, Offline, Failed

proc repoUrl*(): string =
  ## `NYX_REPO` overrides the default repository.
  getEnv("NYX_REPO", DefaultRepo)

proc hasGit*(): bool = findExe("git").len > 0

proc quietEnv(): StringTableRef =
  ## The environment for Git: fail fast instead of waiting on a password
  ## prompt nobody sees. Passed to the child rather than set on this process,
  ## which has no writable environment when built libc-free.
  result = newStringTable(when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["GIT_TERMINAL_PROMPT"] = "0"
  if getEnv("GIT_SSH_COMMAND").isEmptyOrWhitespace:
    result["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"

proc classify(code: int; output: string): GitResult =
  if code == 0: return Done
  let o = output.toLowerAscii
  if "could not resolve host" in o or "couldn't connect" in o or
      "network is unreachable" in o or "connection timed out" in o:
    Offline
  elif "not found" in o or "authentication" in o or "permission denied" in o or
      "could not read" in o or "terminal prompts disabled" in o or
      "does not exist" in o or "403" in o or "access" in o:
    NoAccess
  else:
    Failed

proc collect(p: Process; output: var string): GitResult =
  ## Drain before waiting: a full output pipe would otherwise block Git.
  output = ""
  var code = -1
  var failed = false
  try:
    output = outputStream(p).readAll()
    code = waitForExit(p)
  except:
    failed = true
    try: kill(p)
    except: discard
    try: discard waitForExit(p)
    except: discard
  try: close(p)
  except: failed = true
  result = if failed: Failed else: classify(code, output)

proc git(args: openArray[string]; output: var string): GitResult =
  output = ""
  if not hasGit(): return NoGit
  var p: Process
  try:
    p = startProcess("git", args = args, env = quietEnv(),
                     options = {poUsePath, poStdErrToStdOut})
  except:
    return Failed
  result = collect(p, output)

proc clone*(url: string; dest: Path; output: var string): GitResult =
  git(["clone", "--quiet", "--", url, $dest], output)

proc pull*(dir: Path; output: var string): GitResult =
  ## Fast-forward only: never reset local changes or merge diverged history.
  git(["-C", $dir, "pull", "--quiet", "--ff-only"], output)

proc head*(dir: Path): string =
  ## Current commit of the clone, or "" if it is not readable.
  var o = ""
  result = if git(["-C", $dir, "rev-parse", "HEAD"], o) == Done: o.strip() else: ""

proc changedSkills*(dir: Path; fromRev, toRev: string): seq[string] =
  ## Top-level directories touched between two commits.
  result = @[]
  if fromRev.len == 0 or toRev.len == 0 or fromRev == toRev: return
  var o = ""
  # NUL preserves literal paths; disabling renames reports both sides of a move.
  if git(["-C", $dir, "diff", "--name-only", "--no-renames", "-z", fromRev, toRev], o) != Done:
    return
  for line in o.split('\0'):
    let slash = line.find('/')
    if slash > 0:
      let top = line.substr(0, slash - 1)
      if top notin result: result.add top
