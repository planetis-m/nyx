## Exercise the synchronous Git runner with controlled local output.
import std/[paths, envvars, assertions, strutils, syncio]
import ../src/repo

proc testGitRun*() {.raises.} =
  var output = "stale output"
  let r = pull(path("."), output)
  let expected = getEnv("NYX_GIT_MESSAGE") & repeat("x\0y", parseInt(getEnv("NYX_GIT_BYTES")))
  if output != expected: raiseAssert("Git output must be captured exactly")
  if $r != getEnv("NYX_GIT_RESULT"):
    raiseAssert("Git failure classification must survive draining")
  echo "git run passed"
