## Destination replacements must not redirect copy refresh or removal.

import std/paths
import std/symlinks
import std/[syncio, os, dirs, files, tempfiles]
import ../src/[state, install]

var failures = 0

proc fail(msg: string) =
  echo "FAIL: ", msg
  {.cast(assumeSync).}:
    inc failures

template check(cond: bool; msg: string) =
  if not cond: fail(msg)

proc mkfile(p: Path; content: string) {.raises.} =
  createDir(parentDir(p))
  writeFile($p, content)

proc fixture(root: Path): Project {.raises.} =
  let store = root / path("store")
  mkfile(store / path("alpha") / path("SKILL.md"), "original")
  mkfile(store / path("alpha") / path("refs") / path("note.txt"), "original note")
  mkfile(store / path("alpha") / path("obsolete.txt"), "obsolete")
  result = Project(root: root / path("app"))
  let r = sync(result, store, @[path(".agents/skills")], @["alpha"], copy = true)
  if r.failed.len != 0 or result.installs.len != 1:
    quit "copy fixture failed"

proc leaf(root: Path) {.raises.} =
  var p = fixture(root)
  let dest = p.installs[0].path
  let src = p.installs[0].source
  let outside = root / path("outside.txt")
  mkfile(outside, "outside original")
  discard tryRemoveFile(dest / path("refs") / path("note.txt"))
  createSymlink(outside, dest / path("refs") / path("note.txt"))
  discard tryRemoveFile(dest / path("obsolete.txt"))
  let missing = root / path("missing.txt")
  createSymlink(missing, dest / path("obsolete.txt"))
  writeFile($(src / path("refs") / path("note.txt")), "new upstream")
  writeFile($(src / path("SKILL.md")), "updated")
  mkfile(dest / path("mine.txt"), "user addition")
  resync(p.installs[0])
  check(readFile($outside) == "outside original", "leaf: refresh preserves outside bytes")
  check(not fileExists($missing), "leaf: refresh does not create dangling link target")
  check(symlinkExists(dest / path("refs") / path("note.txt")),
    "leaf: refresh preserves replacement link")
  check(symlinkExists(dest / path("obsolete.txt")), "leaf: refresh preserves dangling replacement")
  check(readFile($(dest / path("SKILL.md"))) == "updated", "leaf: unrelated file refreshes")
  check(not unplace(p.installs[0]), "leaf: removal reports user replacements as kept")
  check(readFile($outside) == "outside original", "leaf: removal preserves outside bytes")
  check(not fileExists($missing), "leaf: removal preserves absent outside target")
  check(symlinkExists(dest / path("refs") / path("note.txt")) and
    symlinkExists(dest / path("obsolete.txt")),
        "leaf: removal preserves both replacement links")
  check(not fileExists($(dest / path("SKILL.md"))), "leaf: ordinary owned file removed")
  check(readFile($(dest / path("mine.txt"))) == "user addition", "leaf: user addition survives")

proc parent(root: Path; refresh, vanished: bool) {.raises.} =
  var p = fixture(root)
  let dest = p.installs[0].path
  let src = p.installs[0].source
  let outside = root / path("outside")
  mkfile(outside / path("note.txt"), "outside original")
  mkfile(outside / path("mine.txt"), "outside addition")
  removeDir(dest / path("refs"))
  createSymlink(outside, dest / path("refs"))
  if vanished:
    removeDir(src / path("refs"))
  else:
    writeFile($(src / path("refs") / path("note.txt")), "new upstream")
    mkfile(src / path("refs") / path("deep") / path("new.txt"), "new child")
  writeFile($(src / path("SKILL.md")), "updated")
  discard tryRemoveFile(src / path("obsolete.txt"))
  if refresh:
    resync(p.installs[0])
    check(fileExists($(outside / path("note.txt"))) and
      readFile($(outside / path("note.txt"))) == "outside original",
          "parent: refresh preserves outside bytes, including obsolete manifest entries")
    check(not taken(outside / path("deep")), "parent: refresh does not create outside directories")
    check(readFile($(dest / path("SKILL.md"))) == "updated", "parent: unrelated file refreshes")
    check(not taken(dest / path("obsolete.txt")), "parent: unrelated obsolete file removed")
  check(not unplace(p.installs[0]), "parent: removal reports replacement as kept")
  check(symlinkExists(dest / path("refs")) and expandSymlink(dest / path("refs")) == outside,
        "parent: replacement directory link survives")
  check(fileExists($(outside / path("note.txt"))),
    "parent: removal preserves outside manifest names")
  if fileExists($(outside / path("note.txt"))):
    check(readFile($(outside / path("note.txt"))) == "outside original",
      "parent: outside bytes survive removal")
  check(readFile($(outside / path("mine.txt"))) == "outside addition",
    "parent: outside additions survive")
  check(not fileExists($(dest / path("SKILL.md"))), "parent: ordinary owned file removed")

proc alias(root: Path) {.raises.} =
  let store = root / path("store")
  mkfile(store / path("alpha") / path("SKILL.md"), "original")
  let actual = root / path("actual")
  mkfile(actual / path("sibling.txt"), "unrelated")
  let configured = root / path("app") / path(".agents") / path("skills")
  createDir(parentDir(configured))
  createSymlink(actual, configured)
  var p = Project(root: root / path("app"))
  let r = sync(p, store, @[path(".agents/skills")], @["alpha"], copy = true)
  check(r.failed.len == 0 and p.installs.len == 1, "alias: copy through configured directory link")
  if p.installs.len != 1: return
  writeFile($(store / path("alpha") / path("SKILL.md")), "updated")
  resync(p.installs[0])
  check(readFile($(actual / path("alpha") / path("SKILL.md"))) == "updated",
    "alias: refresh through configured link")
  check(unplace(p.installs[0]) and not taken(actual / path("alpha")), "alias: owned copy removed")
  check(symlinkExists(configured), "alias: configured directory link preserved")
  check(readFile($(actual / path("sibling.txt"))) == "unrelated", "alias: sibling preserved")

proc replaced(root: Path) {.raises.} =
  var p = fixture(root)
  let dest = p.installs[0].path
  let outside = root / path("outside")
  mkfile(outside / path("SKILL.md"), "user replacement")
  removeDir(dest)
  createSymlink(outside, dest)
  check(not intact(p.installs[0]), "root: replacement link is no longer owned")
  resync(p.installs[0])
  check(not unplace(p.installs[0]), "root: replacement link is kept")
  check(symlinkExists(dest) and expandSymlink(dest) == outside, "root: replacement link survives")
  check(readFile($(outside / path("SKILL.md"))) == "user replacement",
    "root: outside bytes survive")
  check(not taken(outside / path("refs")), "root: refresh does not create outside files")

proc run() {.raises.} =
  let tmp = createTempDir("nyx-links-", "")
  defer: removeDir(tmp)
  leaf(tmp / path("leaf"))
  parent(tmp / path("parent-refresh"), refresh = true, vanished = false)
  parent(tmp / path("parent-stale"), refresh = true, vanished = true)
  parent(tmp / path("parent-remove"), refresh = false, vanished = false)
  alias(tmp / path("alias"))
  replaced(tmp / path("root"))

try:
  run()
except ErrorCode as e:
  echo "UNEXPECTED ERROR: ", $e
  quit 1
if failures != 0: quit 1
echo "Destination link tests passed."
