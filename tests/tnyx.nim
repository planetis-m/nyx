## NYX tests. Everything happens in a fresh temporary directory; git is run
## against local repositories only, so no network is needed.
##
##   nimony c -r tests/tnyx.nim
##
## The temporary parent must have no .git ancestor for the no-repository
## root case.

import std/[syncio, strutils, os, dirs, files, osproc, streams, envvars, tempfiles]
import ../src/[state, catalog, repo, install]
import ../src/ui as ui
import paths, explain

var failures = 0   # single-threaded test program

proc fail(msg: string) =
  echo "FAIL: ", msg
  {.cast(assumeSync).}:
    inc failures

template check(cond: bool; msg: string) =
  if not cond: fail(msg)

proc mkfile(p, content: string) {.raises.} =
  createDir(path(parentDir(p)))
  writeFile(p, content)

proc sh(dir: string; args: openArray[string]): int {.raises.} =
  var all = @["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
  for a in args: all.add a
  let p = startProcess("git", workingDir = dir, args = all,
    options = {poUsePath, poStdErrToStdOut})
  defer: close(p)
  close(p.inputStream)
  discard p.outputStream.readAll()
  result = waitForExit(p)

proc skillMd(desc: string): string =
  "---\nname: x\ndescription: " & desc & "\n---\n\n# Body\n"

proc makeStore(store: string) {.raises.} =
  mkfile(store / "alpha" / "SKILL.md", skillMd("Alpha does things. More text."))
  mkfile(store / "alpha" / "references" / "notes.md", "notes")
  mkfile(store / "beta" / "SKILL.md", "no frontmatter here\n")
  mkfile(store / "gamma" / "SKILL.md",
         "---\nname: gamma\ndescription: >\n  Folded\n  text\n---\n")
  mkfile(store / "not a skill" / "SKILL.md", skillMd("bad name"))
  mkfile(store / ".hidden" / "SKILL.md", skillMd("hidden"))
  mkfile(store / "empty" / "README.md", "no SKILL.md")
  mkfile(store / "README.md", "top level file")

proc testState(tmp: string) {.raises.} =
  let data = tmp / "data"
  var corrupt = true
  var s = loadState(data, corrupt)
  check(not corrupt and s.projects.len == 0, "missing state is fresh, not corrupt")
  check(s.version == SchemaVersion and s.checkEvery == DefaultCheckEvery, "fresh defaults")
  check(s.find("/p") == -1, "unknown project is new")

  s.lastCheck = 1234
  s.repoRev = "abc"
  s.projects.add Project(root: "/p", targets: @["claude", "pi"], skills: @["alpha"],
    installs: @[Install(path: "/p/.claude/skills/alpha", skill: "alpha", mode: Copy,
                        source: "/s/alpha", files: @["SKILL.md", "ref/a \"q\".md"])],
    dirs: @["/p/.claude/skills"])
  saveState(data, s)
  check(not fileExists(statePath(data) & ".tmp"), "temporary file renamed away")
  var back = loadState(data, corrupt)
  check(not corrupt, "round trip parses")
  check(back.lastCheck == 1234 and back.repoRev == "abc", "round trip scalars")
  check(back.find("/p") == 0, "existing project found")
  let p = back.projects[0]
  check(p.targets == @["claude", "pi"] and p.skills == @["alpha"], "round trip lists")
  check(p.installs.len == 1 and p.installs[0].mode == Copy and
        p.installs[0].files[1] == "ref/a \"q\".md", "round trip installs")
  check(p.dirs == @["/p/.claude/skills"], "round trip dirs")

  # A directory at the temporary file path makes opening it fail.
  let saved = readFile(statePath(data))
  createDir(path(statePath(data) & ".tmp"))
  s.repoRev = "must not replace abc"
  var failed = false
  try:
    saveState(data, s)
  except ErrorCode:
    failed = true
  check(failed, "temporary state write failure propagates")
  check(readFile(statePath(data)) == saved, "failed save leaves previous state bytes intact")
  back = loadState(data, corrupt)
  check(not corrupt and back.repoRev == "abc" and back.projects.len == 1,
        "previous state remains readable after failed save")
  removeDir(path(statePath(data) & ".tmp"))

  writeFile(statePath(data), "{\"version\": 1, \"projects\": [tru")
  back = loadState(data, corrupt)
  check(corrupt and back.projects.len == 0, "corrupt state starts fresh")
  check(fileExists(statePath(data) & ".bad"), "corrupt state kept aside")
  check(not fileExists(statePath(data)), "corrupt state not left in place")

  writeFile(statePath(data), "{\"version\": 99}")
  back = loadState(data, corrupt)
  check(corrupt, "unknown schema version is not trusted")

  writeFile(statePath(data), "[1]")
  back = loadState(data, corrupt)
  check(corrupt, "non-object document is not trusted")

proc testStale() =
  var s = newState()
  let t = 100 * 24 * 3600
  check(isStale(s, t), "never checked is stale")
  s.lastCheck = t - 31 * 24 * 3600
  check(isStale(s, t), "31 days is stale")
  s.lastCheck = t - 24 * 3600
  check(not isStale(s, t), "1 day is current")

proc testRoot(tmp: string) {.raises.} =
  let proj = tmp / "proj"
  createDir(path(proj / ".git"))
  createDir(path(proj / "src" / "deep"))
  let real = expandFilename(proj)
  check(projectRoot(proj / "src" / "deep") == real, "root found from a subdirectory")
  check(projectRoot(proj / "src" / ".." / "src") == real, "dot-dot normalized")
  createSymlink(proj, tmp / "alias")
  check(projectRoot(tmp / "alias" / "src") == real, "symlinked path resolves to one key")
  let loose = tmp / "loose"
  createDir(path(loose))
  let looseRoot = projectRoot(loose)
  check(looseRoot == expandFilename(loose), "no git: directory itself; got " & looseRoot &
        ", expected " & expandFilename(loose) &
        "; fixture requires a temporary parent without a .git ancestor (check TMPDIR)")
  mkfile(tmp / "wt" / ".git", "gitdir: elsewhere")
  createDir(path(tmp / "wt" / "a"))
  check(projectRoot(tmp / "wt" / "a") == expandFilename(tmp / "wt"), ".git file (worktree)")

  # The nearest enclosing repository wins.
  let inner = proj / "nested"
  createDir(path(inner / "src" / "deep"))
  check(sh(proj, ["init", "-q"]) == 0 and sh(inner, ["init", "-q"]) == 0,
        "nested local repositories initialized")
  check(projectRoot(inner / "src" / "deep") == expandFilename(inner),
        "nearest inner repository wins over outer repository")

proc testDescription() =
  for (text, desc) in [
    ("", ""),
    ("description: outside frontmatter", ""),
    ("---\n---\ndescription: outside frontmatter", ""),
    (" \t--- \nname: x\ndescription \t:  plain text \t\n---", "plain text"),
    ("---\ndescription:", ""),
    ("---\ndescription: \"\"", ""),
    ("---\ndescription: \"  quoted text  \"\n---", "  quoted text  "),
    ("---\ndescription: 'quoted text'\n---", "quoted text"),
    ("---\ndescription: 'It''s useful'\n---", "It''s useful"),
    ("---\ndescription: text # comment\n---", "text # comment"),
    ("---\n description: ignored\ndescription-x: ignored\n---", ""),
    ("---\ndescription: >-\n  folded\n\ttext\nname: end", "folded text"),
    ("---\ndescription: |\n  literal\n  text\n---", "literal text"),
    ("---\ndescription:\n  \n  folded\n   \n  text\n  \n---", "folded  text"),
    ("---\ndescription: >\n  first\n\n  ignored", "first"),
    ("---\r\ndescription: >\r\n  CRLF\r\n  text\r\n---", "CRLF text"),
    ("---\rdescription: CR text\r---", "CR text"),
    ("---\ndescription: unterminated", "unterminated")]:
    check(readDescription(text) == desc, "description: " & text)

proc testCatalog(tmp: string) {.raises.} =
  let store = tmp / "store"
  makeStore(store)
  createSymlink(store / "alpha", store / "linked")
  # A broken directory link must not hide valid catalog entries.
  createSymlink(store / "missing-skill", store / "broken")
  let skills = discover(store)
  check(skills.names == @["alpha", "beta", "gamma"], "discovery: " & skills.names.join(","))
  check(skills[0].description == "Alpha does things. More text.", "description read")
  check(skills[1].description == "", "missing frontmatter falls back")
  check(skills[2].description == "Folded text", "folded description")
  check(discover(tmp / "nope").len == 0, "missing catalog is empty")
  for bad in ["..", "../x", "/etc", "a/b", "a\\b", ".git", "", "-x"]:
    check(not validName(bad), "rejects name " & bad)
  check(validName("nim-testing") and validName("a_b2"), "accepts plain names")

  # Discovery sorts entries by name.
  let unsorted = tmp / "unsorted-store"
  for name in ["charlie", "alpha", "bravo"]:
    mkfile(unsorted / name / "SKILL.md", skillMd(name))
  let ordered = discover(unsorted)
  check(ordered.names == @["alpha", "bravo", "charlie"],
        "discovery sorts deliberately unsorted creation order")
  for s in ordered:
    check(s.description == s.name, "sorted description belongs to directory " & s.name)
  mkfile(unsorted / "0-first" / "SKILL.md", "---\nname: other\n---\n")
  mkfile(unsorted / "Z-last" / "SKILL.md", skillMd("'quoted'"))
  mkfile(unsorted / "nested" / "child" / "SKILL.md", skillMd("not a direct child"))
  let mixed = discover(unsorted)
  check(mixed.names == @["0-first", "Z-last", "alpha", "bravo", "charlie"],
        "discovery keeps directory identity, flat scope and ASCII ordering")
  check(mixed[0].description == "" and mixed[1].description == "quoted",
        "sorted missing and quoted descriptions")
  let unreadable = unsorted / "bravo" / "SKILL.md"
  let perms = getFilePermissions(path(unreadable))
  try:
    setFilePermissions(unreadable, {})
    var denied = false
    try:
      discard readFile(unreadable)
    except:
      denied = true
    check(denied, "unreadable description fixture requires permission enforcement")
    let partial = discover(unsorted)
    check(partial.names == mixed.names, "unreadable description keeps the skill and ordering")
    check(partial[3].description == "" and partial[4].description == "charlie",
          "unreadable description is empty; later descriptions still read")
  finally:
    setFilePermissions(unreadable, perms)

proc testNames() =
  for s in ["a", "Z", "0", "9", "a_B-09", repeat('a', 63), repeat('Z', 64),
            "0" & repeat('_', 62) & "-"]:
    check(validName(s), "accepts name boundary " & s)
  for s in ["", repeat('a', 65), "_a", "-a", ".a", "a.b", "a/b", "a\\b",
            "a b", "a\t", "a\r", "a\n", "a\v", "a\f", "a\0b", "é", "aé"]:
    check(not validName(s), "rejects name boundary/character " & s)
  for b in 0..255:
    let c = char(b)
    check(validName($c) == (c in {'A'..'Z', 'a'..'z', '0'..'9'}),
          "first name byte " & $b)
    check(validName("a" & $c) == (c in {'A'..'Z', 'a'..'z', '0'..'9', '_', '-'}),
          "later name byte " & $b)

proc testInstall(tmp: string) {.raises.} =
  let store = tmp / "install-store"
  makeStore(store)
  let root = tmp / "app"
  createDir(path(root))
  # Something the user put there themselves.
  mkfile(root / ".claude" / "skills" / "alpha" / "SKILL.md", "user's own alpha")
  var p = Project(root: root)

  var r = sync(p, store, @[".claude/skills", ".pi/skills"], @["alpha", "beta"])
  check(r.collisions == @[root / ".claude/skills/alpha"], "collision reported")
  check(readFile(root / ".claude/skills/alpha/SKILL.md") == "user's own alpha",
        "unmanaged destination untouched")
  check(r.placed.len == 3 and p.installs.len == 3, "other destinations placed")
  check(symlinkExists(root / ".pi/skills/beta"), "linked on unix")
  check(p.dirs == @[root / ".pi", root / ".pi/skills"],
        "created dirs recorded: " & p.dirs.join(","))
  check(missing(p) == 0, "all intact")

  # Deselect beta: its links go, the user's alpha stays.
  r = sync(p, store, @[".claude/skills", ".pi/skills"], @["alpha"])
  check(r.removed.len == 2 and not taken(root / ".pi/skills/beta"), "deselected removed")
  check(fileExists(root / ".claude/skills/alpha/SKILL.md"), "unmanaged survives resync")

  # A copy, modified by the user afterwards.
  var q = Project(root: tmp / "app2")
  createDir(path(q.root))
  let script = store / "alpha" / "scripts" / "run.sh"
  mkfile(script, "#!/bin/sh\necho hi\n")
  setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
  # Copies skip source links, including dangling links.
  createSymlink(script, store / "alpha" / "file-link")
  createSymlink(store / "alpha" / "references", store / "alpha" / "dir-link")
  let vanished = store / "alpha" / "vanished"
  mkfile(vanished, "removed after linking")
  createSymlink(vanished, store / "alpha" / "broken-link")
  check(tryRemoveFile(path(vanished)) == Success, "break source file link")
  r = sync(q, store, @[".agents/skills"], @["alpha"], copy = true)
  let copyDir = q.root / ".agents/skills/alpha"
  check(q.installs.len == 1 and q.installs[0].mode == Copy, "copy mode recorded")
  check(fileExists(copyDir / "references/notes.md"), "copy is recursive")
  check(fpUserExec in getFilePermissions(path(copyDir / "scripts/run.sh")),
        "copy keeps the exec bit")
  check(r.failed.len == 0, "source links do not fail copy installation")
  for name in ["file-link", "dir-link", "broken-link"]:
    check(not taken(copyDir / name), "copy skips source " & name)
    check(name notin q.installs[0].files, "source link is not in copy manifest: " & name)
  check("dir-link/notes.md" notin q.installs[0].files, "copy manifest excludes linked contents")
  writeFile(copyDir / "mine.txt", "user file")

  # Upstream change, then resync of the copy.
  writeFile(store / "alpha" / "SKILL.md", skillMd("Alpha v2."))
  discard tryRemoveFile(path(store / "alpha" / "references" / "notes.md"))
  resync(q.installs[0])
  check("Alpha v2." in readFile(copyDir / "SKILL.md"), "copy resynced")
  check(not fileExists(copyDir / "references/notes.md"), "file dropped upstream removed")
  check(fileExists(copyDir / "mine.txt"), "user file survives resync")
  for name in ["file-link", "dir-link", "broken-link"]:
    check(not taken(copyDir / name), "refresh still skips source " & name)

  # Remove everything NYX made in both projects.
  r = removeAll(p)
  check(r.kept.len == 0 and p.installs.len == 0, "links removed")
  check(not dirExists(root / ".pi"), "empty created dirs pruned")
  check(readFile(root / ".claude/skills/alpha/SKILL.md") == "user's own alpha",
        "remove leaves unmanaged files")
  r = removeAll(q)
  check(r.kept == @[copyDir], "modified copy reported as kept")
  check(fileExists(copyDir / "mine.txt") and not fileExists(copyDir / "SKILL.md"),
        "only NYX's files removed from a copy")

  # A link the user replaced with their own directory is not NYX's any more.
  var u = Project(root: tmp / "app3")
  createDir(path(u.root))
  discard sync(u, store, @[".claude/skills"], @["gamma"])
  let g = u.root / ".claude/skills/gamma"
  discard tryRemoveFile(path(g))
  mkfile(g / "SKILL.md", "replaced")
  check(missing(u) == 1, "replaced install counts as missing")
  r = removeAll(u)
  check(r.kept == @[g] and readFile(g / "SKILL.md") == "replaced", "replacement left alone")

proc testRetargetedLink(tmp: string) {.raises.} =
  # A user-retargeted link no longer belongs to NYX.
  let store = tmp / "retarget-store"
  mkfile(store / "alpha" / "SKILL.md", skillMd("original"))
  let other = tmp / "user-skill"
  mkfile(other / "SKILL.md", "user's target")
  var p = Project(root: tmp / "retarget-app")
  discard sync(p, store, @[".claude/skills"], @["alpha"])
  let inst = p.installs[0]
  check(tryRemoveFile(path(inst.path)) == Success, "remove original installed link")
  createSymlink(other, inst.path)
  check(missing(p) == 1 and not intact(inst), "retargeted link counts as missing")
  check(not unplace(inst) and expandSymlink(inst.path) == other,
        "removal leaves retargeted link alone")
  let r = sync(p, store, @[".claude/skills"], @["alpha"])
  check(r.collisions == @[inst.path] and p.installs.len == 0,
        "resync relinquishes retargeted link and reports collision")
  check(expandSymlink(inst.path) == other and readFile(other / "SKILL.md") == "user's target",
        "resync preserves user link and target")

proc prompt(mode: string) =
  # Child mode: call the real prompts with pipe-backed stdin/stdout. Keeping
  # this in the test executable avoids compiling a second fixture program.
  if mode == "yes" or mode == "no":
    let answer = ui.confirm("Proceed?", mode == "yes")
    echo "answer=", answer
  else:
    let items = @[ui.Choice(label: "first"), ui.Choice(label: "second"),
                  ui.Choice(label: "third")]
    var sel = @[false, true, false]
    ui.choose(items, sel, minOne = mode == "required")
    var answer = ""
    for selected in sel: answer.add(if selected: '1' else: '0')
    echo "answer=", answer

proc runPrompt(mode, input: string): (int, string) {.raises.} =
  let p = startProcess(getAppFilename(), args = @["--prompt", mode],
                       options = {poStdErrToStdOut})
  defer: close(p)
  p.inputStream.write(input)
  close(p.inputStream)  # Deliver EOF, including for abort tests.
  # These three-choice scripts emit less than a pipe buffer. Bound the wait
  # before reading so a prompt regression cannot hang the test indefinitely.
  let code = waitForExit(p, 5000)
  let output = p.outputStream.readAll()
  result = (code, output)

proc testPrompts() {.raises.} =
  # Check prompt answers and rendered output with piped input.
  for (mode, input, answer) in [
      ("yes", "\n", "true"), ("no", "\n", "false"),
      ("no", "  YeS  \n", "true"), ("yes", "No\n", "false"),
      ("yes", "unrecognized\n", "false")]:
    let (code, output) = runPrompt(mode, input)
    let hint = if mode == "yes": "[Y/n]" else: "[y/N]"
    check(code == 0 and output.endsWith("answer=" & answer & "\n"),
          "confirm " & mode & " input [" & input & "]: " & output)
    check("Proceed? " & hint in output, "confirm displays default hint")

  for (mode, input, answer) in [
      ("optional", "\n", "010"),
      ("optional", "1, 2 3\n\n", "101"),
      ("optional", "a\n\n", "111"), ("optional", "n\n\n", "000"),
      ("optional", "garbage 0 -1 99\n\n", "010"),
      ("optional", ",,1,,\t 2\v3\f,,\n\n", "101"),
      ("optional", ",, \t,,\n\n", "010"),
      ("optional", "+1 02 +3\n\n", "101"),
      ("optional", "1_ 2__ +0_3___\n\n", "101"),
      ("optional", "1,1 2 2 +3 3_\n\n", "010"),
      ("optional", "1x 2.0 3_foo _1 +_2 + - --1 0x1 1\x002\n\n", "010"),
      ("optional", "2147483647 2147483648 4294967297 -4294967295\n\n", "010"),
      ("optional", "9223372036854775807 9223372036854775808 " &
        "-9223372036854775808 -9223372036854775809\n\n", "010"),
      ("optional", "1 99999999999999999999999999999 3\n\n", "111"),
      ("optional", "1 9_223_372_036_854_775_808 3\n\n", "111"),
      ("optional", "A N a,1 n\n\n", "110"),
      ("optional", " a \n2\nn\n+3\n\n", "001"),
      ("required", "n\n\n3\n\n", "001")]:
    let (code, output) = runPrompt(mode, input)
    check(code == 0 and output.endsWith("answer=" & answer & "\n"),
          "choose " & mode & " input [" & input & "]: " & output)
    check("first" in output and "third" in output and "[x]" in output and
          "[ ]" in output and "toggle 1-3, a/n, enter to accept" in output,
          "choose draws choices and instructions")
    check(("pick at least one" in output) == (mode == "required"),
          "empty required selection warns and retries")

  let (code, output) = runPrompt("required", "\n")
  check(code == 0 and output.endsWith("answer=010\n") and "pick at least one" notin output,
        "required selection accepts its selected default")

  for (mode, input) in [("yes", ""), ("optional", "1\n"), ("required", "n\n\n")]:
    let (code, output) = runPrompt(mode, input)
    check(code == 1 and "aborted" in output and "answer=" notin output,
          "EOF aborts " & mode & " without returning an answer: " & output)

proc testRepo(tmp: string) {.raises.} =
  var o = ""
  # No access: a repository that is not there.
  let r = repo.clone("file://" & tmp / "missing-repo", tmp / "clone0", o)
  check(r == NoAccess, "missing repository is no access, got " & $r)
  check(not dirExists(tmp / "clone0"), "failed clone leaves nothing")

  # No git at all.
  let hadPath = existsEnv("PATH")
  let oldPath = getEnv("PATH")
  try:
    putEnv("PATH", tmp / "empty-bin")
    o = "stale output"
    check(pull(tmp, o) == NoGit, "git missing detected")
    check(o.len == 0, "missing git clears output")
  finally:
    if hadPath: putEnv("PATH", oldPath)
    else: delEnv("PATH")

  # Upstream change detection through a real (local) repository.
  let origin = tmp / "origin"
  makeStore(origin)
  check(sh(origin, ["init", "-q"]) == 0 and sh(origin, ["add", "-A"]) == 0 and
        sh(origin, ["commit", "-q", "-m", "one"]) == 0, "origin repo")
  let clone = tmp / "clone"
  check(repo.clone(origin, clone, o) == Done, "clone: " & o)
  let before = head(clone)
  writeFile(origin / "beta" / "SKILL.md", skillMd("Beta v2."))
  check(sh(origin, ["commit", "-q", "-am", "two"]) == 0, "second commit")
  check(pull(clone, o) == Done, "pull: " & o)
  check(changedSkills(clone, before, head(clone)) == @["beta"], "changed skills")
  check(changedSkills(clone, head(clone), head(clone)).len == 0, "no change")

proc testChangedSkills(tmp: string) {.raises.} =
  let dir = tmp / "changes"
  mkfile(dir / "alpha" / "SKILL.md", skillMd("Alpha."))
  mkfile(dir / "alpha" / "guide.txt", "unique guide to move between skills\n")
  mkfile(dir / "alpha" / "obsolete.txt", "remove me")
  mkfile(dir / "beta" / "SKILL.md", skillMd("Beta."))
  mkfile(dir / "README.md", "one")
  check(sh(dir, ["init", "-q"]) == 0, "change fixture initialized")
  check(sh(dir, ["config", "core.quotePath", "true"]) == 0 and
        sh(dir, ["config", "diff.renames", "true"]) == 0,
        "change fixture enables path quoting and rename detection")
  check(sh(dir, ["add", "-A"]) == 0 and
        sh(dir, ["commit", "-q", "-m", "initial"]) == 0, "initial change commit")
  var before = head(dir)
  check(before.len > 0, "change fixture has a revision")
  check(changedSkills(dir, "", before).len == 0, "empty starting revision")
  check(changedSkills(dir, before, "").len == 0, "empty ending revision")
  check(changedSkills(dir, before, before).len == 0, "equal revisions")
  check(sh(dir, ["commit", "-q", "--allow-empty", "-m", "same tree"]) == 0,
        "empty commit")
  check(head(dir) != before and changedSkills(dir, before, head(dir)).len == 0,
        "distinct commits with identical trees have no changes")

  before = head(dir)
  mkfile(dir / "alpha" / "SKILL.md", skillMd("Alpha v2."))
  mkfile(dir / "alpha" / "nested" / "notes.txt", "added")
  removeFile(path(dir / "alpha" / "obsolete.txt"))
  mkfile(dir / "beta" / "notes.txt", "also added")
  mkfile(dir / "README.md", "two")
  check(sh(dir, ["add", "-A"]) == 0 and
        sh(dir, ["commit", "-q", "-m", "ordinary changes"]) == 0,
        "ordinary change commit")
  let ordinary = changedSkills(dir, before, head(dir))
  check(ordinary == @["alpha", "beta"],
        "ordinary additions, edits and deletions deduplicate skills: " & ordinary.join(","))

  before = head(dir)
  mkfile(dir / "delta" / "café.txt", "unicode")
  var expected = @["delta"]
  when not defined(windows):
    # These characters are legal filename bytes on POSIX filesystems.
    mkfile(dir / "beta" / "tab\tfile.txt", "tab")
    mkfile(dir / "beta" / "line\nbreak.txt", "newline")
    mkfile(dir / "gamma" / "double\"quote.txt", "quote")
    expected = @["beta", "delta", "gamma"]
  check(sh(dir, ["add", "-A"]) == 0 and
        sh(dir, ["commit", "-q", "-m", "quoted paths"]) == 0, "quoted path commit")
  let quoted = changedSkills(dir, before, head(dir))
  check(quoted == expected, "literal skills from quoted filenames: " & quoted.join(","))

  before = head(dir)
  check(sh(dir, ["mv", "alpha/guide.txt", "beta/guide.txt"]) == 0 and
        sh(dir, ["commit", "-q", "-m", "cross-skill move"]) == 0, "move commit")
  let moved = changedSkills(dir, before, head(dir))
  check(moved == @["alpha", "beta"], "move touches both skills: " & moved.join(","))

  before = head(dir)
  mkfile(dir / "README.md", "root-only change")
  check(sh(dir, ["commit", "-q", "-am", "root only"]) == 0, "root-only commit")
  check(changedSkills(dir, before, head(dir)).len == 0, "root files are not skills")
  check(changedSkills(dir, "not-a-revision", head(dir)).len == 0,
        "failed diff keeps the empty-result policy")

proc testGit(tmp: string) {.raises.} =
  # Do not inherit repository selection, injected config, identities, signing,
  # URL rewrites, hooks or templates from the caller. Snapshot before deleting:
  # envPairs iterates storage that delEnv modifies.
  var saved: seq[(string, string)] = @[]
  for key, value in envPairs():
    if key.startsWith("GIT_") or key == "LC_ALL": saved.add (key, value)
  try:
    for (key, value) in saved: delEnv(key)
    let config = tmp / "gitconfig"
    let empty = tmp / "empty-git"
    createDir(path(empty))
    writeFile(config, "")
    putEnv("GIT_CONFIG_NOSYSTEM", "1")
    putEnv("GIT_CONFIG_GLOBAL", config)
    putEnv("GIT_CONFIG_COUNT", "4")
    for i, (key, value) in [("init.defaultBranch", "main"),
        ("init.templateDir", empty), ("core.hooksPath", empty),
        ("core.autocrlf", "false")]:
      putEnv("GIT_CONFIG_KEY_" & $i, key)
      putEnv("GIT_CONFIG_VALUE_" & $i, value)
    putEnv("GIT_ALLOW_PROTOCOL", "file")
    putEnv("GIT_TERMINAL_PROMPT", "0")
    putEnv("LC_ALL", "C")
    testRoot(tmp)
    testRepo(tmp)
    testChangedSkills(tmp)
  finally:
    var keys: seq[string] = @[]
    for key, value in envPairs():
      if key.startsWith("GIT_") or key == "LC_ALL": keys.add key
    for key in keys: delEnv(key)
    for (key, value) in saved: putEnv(key, value)

proc main() =
  if paramCount() == 2 and paramStr(1) == "--prompt":
    prompt(paramStr(2))
    return
  var tmp = ""
  try:
    tmp = $createTempDir("nyx-test-", "")
    {.cast(assumeSync).}:
      failures += testPaths()
      failures += testFirstLine()
    testState(tmp)
    testStale()
    testDescription()
    testNames()
    testCatalog(tmp)
    testInstall(tmp)
    testRetargetedLink(tmp)
    testPrompts()
    testGit(tmp)
  except ErrorCode as e:
    fail("raised " & $e)
  try:
    if tmp.len > 0: removeDir(path(tmp))
  except ErrorCode as e:
    fail("cleanup raised " & $e)
  check(tmp.len == 0 or not dirExists(tmp), "temporary fixture removed")
  {.cast(assumeSync).}:
    if failures > 0:
      echo failures, " failed"
      quit(1)
  echo "all tests passed"

main()
