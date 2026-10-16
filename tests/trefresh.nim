## Local Git and filesystem tests for applied revisions and copy failures.
import std/paths
import std/[syncio, os, dirs, files, strutils, envvars, tempfiles, osproc, streams]
import refresh

proc main(): int {.raises.} =
  result = 0
  if paramCount() == 2 and paramStr(1) == "--short-copy":
    return testShortCopy(path(paramStr(2)))

  let tmp = createTempDir("nyx-refresh-", "")
  defer: removeDir(tmp)
  var saved: seq[(string, string)] = @[]
  for key, value in envPairs():
    if key.startsWith("GIT_") or key == "LC_ALL": saved.add (key, value)
  defer:
    var keys: seq[string] = @[]
    for key, value in envPairs():
      if key.startsWith("GIT_") or key == "LC_ALL": keys.add key
    for key in keys: delEnv(key)
    for (key, value) in saved: putEnv(key, value)
  for (key, value) in saved: delEnv(key)
  let empty = tmp / path("empty-git")
  createDir(empty)
  writeFile($(tmp / path("gitconfig")), "")
  putEnv("GIT_CONFIG_NOSYSTEM", "1")
  putEnv("GIT_CONFIG_GLOBAL", $(tmp / path("gitconfig")))
  putEnv("GIT_CONFIG_COUNT", "4")
  for i, (key, value) in [("init.defaultBranch", "main"),
      ("init.templateDir", $empty), ("core.hooksPath", $empty), ("core.autocrlf", "false")]:
    putEnv("GIT_CONFIG_KEY_" & $i, key)
    putEnv("GIT_CONFIG_VALUE_" & $i, value)
  putEnv("GIT_ALLOW_PROTOCOL", "file")
  putEnv("GIT_TERMINAL_PROMPT", "0")
  putEnv("LC_ALL", "C")

  var failures = testRefresh(tmp)
  when defined(posix):
    let short = tmp / path("short")
    createDir(short / path("store/alpha"))
    writeFile($(short / path("store/alpha/large.txt")), repeat('x', 4096))
    let p = startProcess("/bin/sh", args = @["-c",
      "trap '' XFSZ; ulimit -f 1; exec \"$1\" --short-copy \"$2\"",
      "short-copy", getAppFilename(), $short], options = {poStdErrToStdOut})
    defer: close(p)
    close(p.inputStream)
    # Assertion output fits in a pipe; bound teardown if copying ever hangs.
    let code = waitForExit(p, 5000)
    let output = p.outputStream.readAll()
    echo output
    if code != 0: inc failures
  if failures > 0:
    echo failures, " refresh tests failed"
    result = 1
  else:
    result = 0
    echo "refresh tests passed"

try:
  let code = main()
  if code != 0: quit(code)
except ErrorCode as e:
  echo "refresh tests raised: ", $e
  quit(1)
