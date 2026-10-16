## Path formatting tests.
import std/syncio
import paths

try:
  let failures = testPaths()
  if failures > 0: quit(1)
except:
  echo "path tests raised"
  quit(1)
echo "path tests passed"
