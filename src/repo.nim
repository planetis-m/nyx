## The skills repository, fetched with the `git` executable. Access comes
## from the user's own GitHub authentication; NYX never asks for credentials,
## and git is told not to prompt for them either.
##
## This is the only module that knows skills come from git.

import std/[strutils, os, osproc, streams, envvars]

const DefaultRepo* = "https://github.com/planetis-m/skills"

type
  GitResult* = enum
    Done, NoGit, NoAccess, Offline, Failed

  Job* = object
    ## A running git command.
    p: Process
    started: bool

proc repoUrl*(): string =
  ## `NYX_REPO` overrides the default repository.
  getEnv("NYX_REPO", DefaultRepo)

proc hasGit*(): bool = findExe("git").len > 0

proc quietGit() =
  ## Fail fast instead of waiting on a password prompt nobody sees.
  try:
    putEnv("GIT_TERMINAL_PROMPT", "0")
    if getEnv("GIT_SSH_COMMAND").len == 0:
      putEnv("GIT_SSH_COMMAND", "ssh -o BatchMode=yes")
  except:
    discard

proc start(args: openArray[string]): Job =
  if not hasGit(): return Job(started: false)
  quietGit()
  try:
    result = Job(p: startProcess("git", args = args,
                                 options = {poUsePath, poStdErrToStdOut}),
                 started: true)
  except:
    result = Job(started: false)

proc startClone*(url, dest: string): Job =
  start(["clone", "--quiet", "--", url, dest])

proc startPull*(dir: string): Job =
  ## Fast-forward only: local changes or diverged history make it fail
  ## rather than being reset or merged away.
  start(["-C", dir, "pull", "--quiet", "--ff-only"])

proc running*(j: Job): bool =
  result = false
  if j.started:
    try:
      result = running(j.p)
    except:
      result = false

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

proc finish*(j: Job; output: var string): GitResult =
  ## Wait for the job and classify how it ended.
  output = ""
  if not j.started:
    return if hasGit(): Failed else: NoGit
  var code = -1
  try:
    output = outputStream(j.p).readAll()   # drain first: a full pipe blocks git
    code = waitForExit(j.p)
    close(j.p)
  except:
    return Failed
  result = classify(code, output)

proc git(args: openArray[string]; output: var string): GitResult =
  finish(start(args), output)

proc head*(dir: string): string =
  ## Current commit of the clone, or "" if it is not readable.
  var o = ""
  result = if git(["-C", dir, "rev-parse", "HEAD"], o) == Done: o.strip() else: ""

proc changedSkills*(dir, fromRev, toRev: string): seq[string] =
  ## Top-level directories touched between two commits.
  result = @[]
  if fromRev.len == 0 or toRev.len == 0 or fromRev == toRev: return
  var o = ""
  # NUL preserves literal paths; disabling renames reports both sides of a move.
  if git(["-C", dir, "diff", "--name-only", "--no-renames", "-z", fromRev, toRev], o) != Done:
    return
  for line in o.split('\0'):
    let slash = line.find('/')
    if slash > 0:
      let top = line.substr(0, slash - 1)
      if top notin result: result.add top
