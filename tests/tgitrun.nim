## Git subprocess tests.
import std/[syncio, envvars]
import gitrun, repoio
try:
  if getEnv("NYX_GIT_FAULT") == "1": testReadFailure()
  else: testGitRun()
except:
  quit(1)
