## Exercise read-exception cleanup through the production process lifecycle.
include ../src/repo
import std/[assertions, syncio]
when defined(posix):
  import std/posix/posix

proc failRead(s: Stream; buffer: pointer; size: int): int {.nimcall, raises.} =
  raise IOError

proc testReadFailure*() {.raises.} =
  when defined(posix):
    let p = startProcess("git", args = ["-C", ".", "pull", "--quiet", "--ff-only"],
                         options = {poUsePath, poStdErrToStdOut})
    let pid = Pid(processID(p))
    let input = inputHandle(p)
    outputStream(p).readDataImpl = failRead
    var output = "stale output"
    if collect(p, output) != Failed: raiseAssert("read error must fail the job")
    if output.len != 0: raiseAssert("read error must clear stale output")
    var status = 0'i32
    if pcall(waitpid(pid, status, WNOHANG)) != -ECHILD:
      raiseAssert("failed Git must be reaped")
    if pcall(fcntl(input, F_GETFL)) != -EBADF:
      raiseAssert("failed Git pipe must be closed")
    echo "git run passed"
