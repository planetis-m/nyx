## Applied-revision and copy-recovery tests.
include ../src/nyx
import std/[files, osproc, streams, envvars]

proc mkfile(file, text: string) {.raises.} =
  createDir(path(parentDir(file)))
  writeFile(file, text)

proc git(dir: string; args: openArray[string]) {.raises.} =
  var all = @["-c", "user.name=test", "-c", "user.email=test@example.invalid",
    "-c", "commit.gpgsign=false"]
  for a in args: all.add a
  let p = startProcess("git", workingDir = dir, args = all,
    options = {poUsePath, poStdErrToStdOut})
  defer: close(p)
  close(p.inputStream)
  let output = p.outputStream.readAll()
  if waitForExit(p) != 0:
    echo output
    quit(1)

proc fixture(tmp: string): Ctx {.raises.} =
  let origin = tmp / "origin"
  mkfile(origin / "alpha/SKILL.md", "version one")
  mkfile(origin / "alpha/obsolete.txt", "old owned file")
  git(origin, ["init", "-q"])
  git(origin, ["add", "-A"])
  git(origin, ["commit", "-qm", "one"])
  result = Ctx(data: tmp / "data", root: tmp / "app", st: newState())
  createDir(path(result.data))
  git(tmp, ["clone", "-q", origin, skillsDir(result.data)])
  var p = Project(root: result.root)
  let rep = sync(p, skillsDir(result.data), @[".agents/skills"], @["alpha"], copy = true)
  if rep.failed.len > 0 or p.installs.len != 1: quit(1)
  mkfile(p.installs[0].path / "mine.txt", "user addition")
  mkfile(tmp / "outside.txt", "outside file")
  result.st.projects.add p
  result.st.repoRev = head(skillsDir(result.data))
  save(result)

proc advance(tmp: string; blocked = false) {.raises.} =
  let origin = tmp / "origin"
  mkfile(origin / "alpha/SKILL.md", "version two")
  mkfile(origin / "alpha/new.txt", "new owned file")
  removeFile(path(origin / "alpha/obsolete.txt"))
  if blocked: mkfile(origin / "alpha/blocked/note.txt", "new nested file")
  git(origin, ["add", "-A"])
  git(origin, ["commit", "-qm", "two"])

proc reload(c: var Ctx) =
  c.st = loadState(c.data, c.corrupt)
  if c.corrupt: quit(1)

proc testRefresh*(tmp: string): int {.raises.} =
  result = 0
  template check(cond: bool; label: string) =
    if not cond:
      echo "FAIL: refresh: ", label
      inc result

  block interrupted:
    let root = tmp / "interrupted"
    var c = fixture(root)
    let dest = c.st.projects[0].installs[0].path
    advance(root)
    # A prior run pulled successfully and stopped before applying the copy.
    git(skillsDir(c.data), ["pull", "--quiet", "--ff-only"])
    reload(c)
    check(c.st.repoRev != head(skillsDir(c.data)), "fixture has unapplied clone HEAD")
    check(refresh(c), "interrupted refresh completes")
    reload(c)
    check(readFile(dest / "SKILL.md") == "version two", "retry uses persisted applied revision")
    check(c.st.repoRev == head(skillsDir(c.data)), "applied revision advances after retry")
    check(not fileExists(dest / "obsolete.txt"), "obsolete copy removed after success")
    check(readFile(dest / "mine.txt") == "user addition", "retry preserves user addition")
    check(readFile(root / "outside.txt") == "outside file", "retry preserves outside file")

  block failed:
    let root = tmp / "failed"
    var c = fixture(root)
    let dest = c.st.projects[0].installs[0].path
    let applied = c.st.repoRev
    mkfile(dest / "blocked", "user blocker")
    advance(root, blocked = true)
    discard refresh(c)
    reload(c)
    check(c.st.repoRev == applied, "failed copy retains applied revision")
    check(c.st.lastCheck > 0, "failed copy records check time")
    check("obsolete.txt" in c.st.projects[0].installs[0].files and
      fileExists(dest / "obsolete.txt"), "failed refresh retains old ownership and file")
    check(fileExists(dest / "new.txt"), "fixture copied a new file before later failure")
    check("new.txt" in c.st.projects[0].installs[0].files,
      "failed refresh persists newly copied ownership")
    check(readFile(dest / "blocked") == "user blocker", "copy failure leaves blocker intact")
    removeFile(path(dest / "blocked"))
    let pulled = head(skillsDir(c.data))
    check(refresh(c), "retry after fixture repair completes")
    reload(c)
    check(head(skillsDir(c.data)) == pulled, "retry pull has no new commit")
    check(fileExists(dest / "blocked/note.txt") and
      readFile(dest / "blocked/note.txt") == "new nested file", "retry completes missed copy")
    check(c.st.repoRev == pulled, "successful retry advances applied revision")
    check(not fileExists(dest / "obsolete.txt"), "successful retry prunes obsolete file")
    check(readFile(dest / "mine.txt") == "user addition", "failed retry preserves user addition")
    check(readFile(root / "outside.txt") == "outside file", "failed retry preserves outside file")

  block partial:
    let root = tmp / "partial"
    var c = fixture(root)
    let dest = c.st.projects[0].installs[0].path
    mkfile(dest / "blocked", "user blocker")
    advance(root, blocked = true)
    discard refresh(c)
    reload(c)
    discard removeAll(c.st.projects[0])
    check(not fileExists(dest / "new.txt"), "remove cleans new file from failed refresh")
    check(not fileExists(dest / "obsolete.txt"), "remove retains ownership of obsolete file")
    check(readFile(dest / "mine.txt") == "user addition" and
      readFile(dest / "blocked") == "user blocker", "remove preserves unmanaged files")
    check(readFile(root / "outside.txt") == "outside file", "partial cleanup preserves outside")

  block normal:
    let root = tmp / "normal"
    var c = fixture(root)
    let dest = c.st.projects[0].installs[0].path
    advance(root)
    check(refresh(c), "normal refresh succeeds")
    reload(c)
    check(readFile(dest / "SKILL.md") == "version two", "normal refresh updates copy")
    let files = c.st.projects[0].installs[0].files
    let rev = c.st.repoRev
    check(refresh(c), "unchanged refresh succeeds")
    reload(c)
    check(c.st.repoRev == rev and c.st.projects[0].installs[0].files == files,
      "unchanged refresh is idempotent")
    check(readFile(dest / "mine.txt") == "user addition", "normal refresh preserves user file")

  for revision in ["", "not-an-available-revision"]:
    let root = tmp / (if revision.len == 0: "empty" else: "unavailable")
    var c = fixture(root)
    let dest = c.st.projects[0].installs[0].path
    advance(root)
    git(skillsDir(c.data), ["pull", "--quiet", "--ff-only"])
    c.st.repoRev = revision
    save(c)
    check(refresh(c), "fallback refresh succeeds: " & revision)
    reload(c)
    check(readFile(dest / "SKILL.md") == "version two", "revision fallback updates copies")
    check(c.st.repoRev == head(skillsDir(c.data)), "fallback stores applied revision")

  block emptyHead:
    let root = tmp / "empty-head"
    var c = fixture(root)
    let applied = c.st.repoRev
    let dest = c.st.projects[0].installs[0].path
    removeDir(path(skillsDir(c.data)))
    let origin = root / "empty-origin"
    createDir(path(origin))
    git(origin, ["init", "-q"])
    let hadRepo = existsEnv("NYX_REPO")
    let oldRepo = getEnv("NYX_REPO")
    try:
      putEnv("NYX_REPO", origin)
      check(refresh(c), "empty repository clone completes")
    finally:
      if hadRepo: putEnv("NYX_REPO", oldRepo)
      else: delEnv("NYX_REPO")
    reload(c)
    check(head(skillsDir(c.data)).len == 0, "fixture has unavailable clone HEAD")
    check(c.st.repoRev == applied, "unavailable HEAD does not erase applied revision")
    check(readFile(dest / "SKILL.md") == "version one", "vanished source keeps last copy")

proc testShortCopy*(tmp: string): int {.raises.} =
  ## The parent limits this child's file size, so real copy I/O fails after
  ## creating the destination.
  result = 0
  template check(cond: bool; label: string) =
    if not cond:
      echo "FAIL: short copy: ", label
      inc result
  let store = tmp / "store"
  var p = Project(root: tmp / "initial")
  let rep = sync(p, store, @["skills"], @["alpha"], copy = true)
  check(rep.failed.len == 1 and p.installs.len == 1, "initial partial install is recorded")
  let dest = p.installs[0].path
  check(fileExists(dest / "large.txt") and readFile(dest / "large.txt").len < 4096,
    "initial copy failed after destination creation")
  check("large.txt" in p.installs[0].files, "initial partial file ownership is recorded")
  discard removeAll(p)
  check(not fileExists(dest / "large.txt"), "initial partial file is removed")

  var inst = Install(path: tmp / "refresh", source: store / "alpha", mode: Copy,
    files: @["old.txt"])
  createDir(path(inst.path))
  mkfile(inst.path / "old.txt", "old owned file")
  mkfile(inst.path / "mine.txt", "user addition")
  var failed = false
  try:
    resync(inst)
  except ErrorCode:
    failed = true
  check(failed and fileExists(inst.path / "large.txt"), "refresh leaves real partial destination")
  check("large.txt" in inst.files and "old.txt" in inst.files,
    "failed individual copy retains old and partial ownership")
  discard unplace(inst)
  check(not fileExists(inst.path / "large.txt") and not fileExists(inst.path / "old.txt"),
    "remove cleans partial and old owned files")
  check(readFile(inst.path / "mine.txt") == "user addition", "partial copy keeps user file")

  # Failure before opening the destination must not adopt a user's existing
  # file. This needs ordinary permission checks.
  let source = store / "alpha/large.txt"
  let permissions = getFilePermissions(path(source))
  inst = Install(path: tmp / "untouched", source: store / "alpha", mode: Copy)
  mkfile(inst.path / "large.txt", "user file")
  try:
    setFilePermissions(path(source), {})
    failed = false
    try:
      resync(inst)
    except ErrorCode:
      failed = true
    check(failed and readFile(inst.path / "large.txt") == "user file",
      "early source failure leaves existing destination untouched")
    check("large.txt" notin inst.files, "early failure does not adopt existing unowned file")
    discard unplace(inst)
    check(readFile(inst.path / "large.txt") == "user file", "remove preserves unowned file")
  finally:
    setFilePermissions(path(source), permissions)
