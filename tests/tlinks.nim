## Destination replacements must not redirect copy refresh or removal.

import std/[syncio, os, dirs, files, tempfiles]
import ../src/[state, install]

var failures = 0

proc fail(msg: string) =
  echo "FAIL: ", msg
  {.cast(assumeSync).}:
    inc failures

template check(cond: bool; msg: string) =
  if not cond: fail(msg)

proc mkfile(p, content: string) {.raises.} =
  createDir(path(parentDir(p)))
  writeFile(p, content)

proc fixture(root: string): Project {.raises.} =
  let store = root / "store"
  mkfile(store / "alpha" / "SKILL.md", "original")
  mkfile(store / "alpha" / "refs" / "note.txt", "original note")
  mkfile(store / "alpha" / "obsolete.txt", "obsolete")
  result = Project(root: root / "app")
  let r = sync(result, store, @[".agents/skills"], @["alpha"], copy = true)
  if r.failed.len != 0 or result.installs.len != 1:
    quit "copy fixture failed"

proc leaf(root: string) {.raises.} =
  var p = fixture(root)
  let dest = p.installs[0].path
  let src = p.installs[0].source
  let outside = root / "outside.txt"
  mkfile(outside, "outside original")
  discard tryRemoveFile(path(dest / "refs" / "note.txt"))
  createSymlink(outside, dest / "refs" / "note.txt")
  discard tryRemoveFile(path(dest / "obsolete.txt"))
  let missing = root / "missing.txt"
  createSymlink(missing, dest / "obsolete.txt")
  writeFile(src / "refs" / "note.txt", "new upstream")
  writeFile(src / "SKILL.md", "updated")
  mkfile(dest / "mine.txt", "user addition")
  resync(p.installs[0])
  check(readFile(outside) == "outside original", "leaf: refresh preserves outside bytes")
  check(not fileExists(missing), "leaf: refresh does not create dangling link target")
  check(symlinkExists(dest / "refs" / "note.txt"), "leaf: refresh preserves replacement link")
  check(symlinkExists(dest / "obsolete.txt"), "leaf: refresh preserves dangling replacement")
  check(readFile(dest / "SKILL.md") == "updated", "leaf: unrelated file refreshes")
  check(not unplace(p.installs[0]), "leaf: removal reports user replacements as kept")
  check(readFile(outside) == "outside original", "leaf: removal preserves outside bytes")
  check(not fileExists(missing), "leaf: removal preserves absent outside target")
  check(symlinkExists(dest / "refs" / "note.txt") and symlinkExists(dest / "obsolete.txt"),
        "leaf: removal preserves both replacement links")
  check(not fileExists(dest / "SKILL.md"), "leaf: ordinary owned file removed")
  check(readFile(dest / "mine.txt") == "user addition", "leaf: user addition survives")

proc parent(root: string; refresh, vanished: bool) {.raises.} =
  var p = fixture(root)
  let dest = p.installs[0].path
  let src = p.installs[0].source
  let outside = root / "outside"
  mkfile(outside / "note.txt", "outside original")
  mkfile(outside / "mine.txt", "outside addition")
  removeDir(path(dest / "refs"))
  createSymlink(outside, dest / "refs")
  if vanished:
    removeDir(path(src / "refs"))
  else:
    writeFile(src / "refs" / "note.txt", "new upstream")
    mkfile(src / "refs" / "deep" / "new.txt", "new child")
  writeFile(src / "SKILL.md", "updated")
  discard tryRemoveFile(path(src / "obsolete.txt"))
  if refresh:
    resync(p.installs[0])
    check(fileExists(outside / "note.txt") and readFile(outside / "note.txt") == "outside original",
          "parent: refresh preserves outside bytes, including obsolete manifest entries")
    check(not taken(outside / "deep"), "parent: refresh does not create outside directories")
    check(readFile(dest / "SKILL.md") == "updated", "parent: unrelated file refreshes")
    check(not taken(dest / "obsolete.txt"), "parent: unrelated obsolete file removed")
  check(not unplace(p.installs[0]), "parent: removal reports replacement as kept")
  check(symlinkExists(dest / "refs") and expandSymlink(dest / "refs") == outside,
        "parent: replacement directory link survives")
  check(fileExists(outside / "note.txt"), "parent: removal preserves outside manifest names")
  if fileExists(outside / "note.txt"):
    check(readFile(outside / "note.txt") == "outside original", "parent: outside bytes survive removal")
  check(readFile(outside / "mine.txt") == "outside addition", "parent: outside additions survive")
  check(not fileExists(dest / "SKILL.md"), "parent: ordinary owned file removed")

proc alias(root: string) {.raises.} =
  let store = root / "store"
  mkfile(store / "alpha" / "SKILL.md", "original")
  let actual = root / "actual"
  mkfile(actual / "sibling.txt", "unrelated")
  let configured = root / "app" / ".agents" / "skills"
  createDir(path(parentDir(configured)))
  createSymlink(actual, configured)
  var p = Project(root: root / "app")
  let r = sync(p, store, @[".agents/skills"], @["alpha"], copy = true)
  check(r.failed.len == 0 and p.installs.len == 1, "alias: copy through configured directory link")
  if p.installs.len != 1: return
  writeFile(store / "alpha" / "SKILL.md", "updated")
  resync(p.installs[0])
  check(readFile(actual / "alpha" / "SKILL.md") == "updated", "alias: refresh through configured link")
  check(unplace(p.installs[0]) and not taken(actual / "alpha"), "alias: owned copy removed")
  check(symlinkExists(configured), "alias: configured directory link preserved")
  check(readFile(actual / "sibling.txt") == "unrelated", "alias: sibling preserved")

proc replaced(root: string) {.raises.} =
  var p = fixture(root)
  let dest = p.installs[0].path
  let outside = root / "outside"
  mkfile(outside / "SKILL.md", "user replacement")
  removeDir(path(dest))
  createSymlink(outside, dest)
  check(not intact(p.installs[0]), "root: replacement link is no longer owned")
  resync(p.installs[0])
  check(not unplace(p.installs[0]), "root: replacement link is kept")
  check(symlinkExists(dest) and expandSymlink(dest) == outside, "root: replacement link survives")
  check(readFile(outside / "SKILL.md") == "user replacement", "root: outside bytes survive")
  check(not taken(outside / "refs"), "root: refresh does not create outside files")

proc run() {.raises.} =
  let tmp = $createTempDir("nyx-links-", "")
  defer: removeDir(path(tmp))
  leaf(tmp / "leaf")
  parent(tmp / "parent-refresh", refresh = true, vanished = false)
  parent(tmp / "parent-stale", refresh = true, vanished = true)
  parent(tmp / "parent-remove", refresh = false, vanished = false)
  alias(tmp / "alias")
  replaced(tmp / "root")

try:
  run()
except ErrorCode as e:
  echo "UNEXPECTED ERROR: ", $e
  quit 1
if failures != 0: quit 1
echo "Destination link tests passed."
