## NYX tests. Everything happens in a fresh temporary directory; git is run
## against local repositories only, so no network is needed.
##
##   nimony c -r tests/tnyx.nim
##
## The temporary parent must have no .git ancestor for the no-repository
## root case.

import std/paths
import std/symlinks
import std/[syncio, strutils, os, dirs, files, osproc, streams, envvars, tempfiles]
import ../src/[state, catalog, repo, install, targets]
import ../src/ui
import paths, explain

var failures = 0   # single-threaded test program

proc fail(msg: string) =
  echo "FAIL: ", msg
  {.cast(assumeSync).}:
    inc failures

template check(cond: bool; msg: string) =
  if not cond: fail(msg)

proc mkfile(p: Path; content: string) {.raises.} =
  createDir(parentDir(p))
  writeFile($p, content)

proc sh(dir: Path; args: openArray[string]): int {.raises.} =
  var all = @["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
  for a in args: all.add a
  let p = startProcess("git", workingDir = $dir, args = all,
    options = {poUsePath, poStdErrToStdOut})
  defer: close(p)
  close(p.inputStream)
  discard p.outputStream.readAll()
  result = waitForExit(p)

proc skillMd(desc: string): string =
  "---\nname: x\ndescription: " & desc & "\n---\n\n# Body\n"

proc makeStore(store: Path) {.raises.} =
  mkfile(store / path("alpha") / path("SKILL.md"), skillMd("Alpha does things. More text."))
  mkfile(store / path("alpha") / path("references") / path("notes.md"), "notes")
  mkfile(store / path("beta") / path("SKILL.md"), "no frontmatter here\n")
  mkfile(store / path("gamma") / path("SKILL.md"),
         "---\nname: gamma\ndescription: >\n  Folded\n  text\n---\n")
  mkfile(store / path("not a skill") / path("SKILL.md"), skillMd("bad name"))
  mkfile(store / path(".hidden") / path("SKILL.md"), skillMd("hidden"))
  mkfile(store / path("empty") / path("README.md"), "no SKILL.md")
  mkfile(store / path("README.md"), "top level file")

proc testTargets(tmp: Path) {.raises.} =
  let root = tmp / path("target-project")
  let home = tmp / path("target-home")
  let config = tmp / path("target-config")
  let bin = tmp / path("target-bin")
  for dir in [root, home, config, bin]: createDir(dir)
  var saved: seq[(string, bool, string)] = @[]
  for key in ["PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME"]:
    saved.add (key, existsEnv(key), getEnv(key))
  try:
    for (key, had, value) in saved: delEnv(key)
    putEnv("PATH", $bin)
    let all = allTargets()
    for t in all:
      check(not detect(t, root, home), "no markers for " & t.id)
    check(byId("unknown") == -1, "unknown target")

    let shared = @["codex", "agents", "cursor", "opencode", "agy", "copilot", "amp", "goose"]
    check(skillDirs(shared) == @[path(".agents/skills")], "shared targets install once")
    check(skillDirs(@["cursor", "claude", "unknown", "opencode", "windsurf", "roo",
                     "continue", "goose"]) ==
          @[path(".agents/skills"), path(".claude/skills"), path(".devin/skills"),
            path(".roo/skills"), path(".continue/skills")],
              "distinct target paths")

    createDir(root / path(".agents"))
    check(detect(all[byId("agents")], root, home), "shared project marker")
    for id in shared:
      if id != "agents":
        check(not detect(all[byId(id)], root, home), "shared directory does not identify " & id)
    createDir(root / path(".cursor"))
    check(detect(all[byId("cursor")], root, home), "Cursor project marker")
    check(not dirExists($(root / path(".agents/skills"))) and
      not dirExists($(root / path(".cursor/skills"))),
          "detection creates no skill directories")
    createDir(root / path(".cline"))
    check(detect(all[byId("cline")], root, home), "Cline project marker")
    mkfile(root / path("opencode.jsonc"), "{}")
    check(detect(all[byId("opencode")], root, home), "OpenCode config marker")
    mkfile(root / path("GEMINI.md"), "instructions")
    check(detect(all[byId("agy")], root, home), "Antigravity instructions marker")
    mkfile(root / path(".github/copilot-instructions.md"), "instructions")
    check(detect(all[byId("copilot")], root, home), "Copilot instructions marker")
    createDir(home / path(".roo"))
    check(detect(all[byId("roo")], root, home), "Roo home marker")

    for (id, key, marker) in [("claude", "CLAUDE_CONFIG_DIR", ".claude"),
                              ("codex", "CODEX_HOME", ".codex")]:
      let t = all[byId(id)]
      createDir(home / path(marker))
      putEnv(key, $(config / path(id)))
      check(not detect(t, root, home), "override replaces default home for " & id)
      createDir(config / path(id))
      check(detect(t, root, home), "config override detects " & id)
      putEnv(key, " \t ")
      check(detect(t, root, home), "blank override uses default home for " & id)

    let bare = tmp / path("unmarked-project")
    createDir(home / path(".config/crush"))
    putEnv("XDG_CONFIG_HOME", $config)
    for id in ["amp", "crush", "goose", "opencode"]:
      check(not detect(all[byId(id)], bare, home), "XDG root alone does not identify " & id)
    createDir(config / path("goose"))
    check(detect(all[byId("goose")], bare, home), "Goose under XDG root")
    check(not detect(all[byId("amp")], bare, home), "Goose config does not identify Amp")
    putEnv("XDG_CONFIG_HOME", "")
    check(detect(all[byId("crush")], bare, home), "default config root")

    let exe = bin / path(when defined(windows): "cn.exe" else: "cn")
    mkfile(exe, "")
    when not defined(windows):
      setFilePermissions(exe, {fpUserRead, fpUserWrite, fpUserExec})
    check(detect(all[byId("continue")], bare, home), "Continue executable on PATH")

    # Global skill directory resolution
    putEnv("XDG_CONFIG_HOME", $config)
    check(globalSkillDir(all[byId("crush")], home) == config / path("crush/skills"),
          "Crush honors XDG_CONFIG_HOME")
    check(globalSkillDir(all[byId("opencode")], home) == config / path("opencode/skills"),
          "OpenCode honors XDG_CONFIG_HOME")
    check(globalSkillDir(all[byId("windsurf")], home) == config / path("devin/skills"),
          "Windsurf honors XDG_CONFIG_HOME")
    check(globalSkillDir(all[byId("claude")], home) == home / path(".claude/skills"),
          "Claude stays under home despite XDG_CONFIG_HOME")
    check(globalSkillDir(all[byId("agy")], home) == home / path(".gemini/config/skills"),
          "Antigravity stays under home despite XDG_CONFIG_HOME")
    check(globalSkillDir(all[byId("amp")], home) == home / path(".config/agents/skills"),
          "Amp's .config is literal, not XDG_CONFIG_HOME")
    check(globalSkillDir(all[byId("codex")], home) == home / path(".agents/skills"),
          "Codex stays under home")
    check(globalSkillDirs(@["codex", "agents", "goose"], home) == @[home / path(".agents/skills")],
          "shared home targets deduplicate")

    putEnv("XDG_CONFIG_HOME", "")
    check(globalSkillDir(all[byId("crush")], home) == home / path(".config/crush/skills"),
          "Crush falls back to ~/.config")
    check(globalSkillDir(all[byId("opencode")], home) == home / path(".config/opencode/skills"),
          "OpenCode falls back to ~/.config")
    check(globalSkillDir(all[byId("windsurf")], home) == home / path(".config/devin/skills"),
          "Windsurf falls back to ~/.config")
    putEnv("XDG_CONFIG_HOME", " \t ")
    check(globalSkillDir(all[byId("crush")], home) == home / path(".config/crush/skills"),
          "blank XDG_CONFIG_HOME falls back to ~/.config")
    putEnv("CLAUDE_CONFIG_DIR", $(config / path("claude")))
    check(globalSkillDir(all[byId("claude")], home) == config / path("claude/skills"),
          "Claude honors CLAUDE_CONFIG_DIR")

    # Global detection does not consider project markers
    check(not detect(all[byId("agents")], path(""), home), "empty root ignores project markers")
    check(detect(all[byId("crush")], path(""), home), "empty root detects home markers")
  finally:
    for (key, had, value) in saved:
      if had: putEnv(key, value)
      else: delEnv(key)

proc testState(tmp: Path) {.raises.} =
  let data = tmp / path("data")
  var corrupt = true
  var s = loadState(data, corrupt)
  check(not corrupt and s.projects.len == 0, "missing state is fresh, not corrupt")
  check(s.version == SchemaVersion and s.checkEvery == DefaultCheckEvery, "fresh defaults")
  check(s.find(path("/p")) == -1, "unknown project is new")

  s.lastCheck = 1234
  s.repoRev = "abc"
  s.projects.add Project(root: path("/p"), targets: @["claude", "pi"], skills: @["alpha"],
    installs: @[Install(path: path("/p/.claude/skills/alpha"), skill: "alpha", mode: Copy,
                        source: path("/s/alpha"), files: @[path("SKILL.md"),
                          path("ref/a \"q\".md")])],
    dirs: @[path("/p/.claude/skills")])
  saveState(data, s)
  check(not fileExists($(data / path("state.json.tmp"))), "temporary file renamed away")
  var back = loadState(data, corrupt)
  check(not corrupt, "round trip parses")
  check(back.lastCheck == 1234 and back.repoRev == "abc", "round trip scalars")
  check(back.find(path("/p")) == 0, "existing project found")
  check(back.find(path("/p/.")) == 0, "project keys use normalized Path equality")
  when FileSystemCaseSensitive:
    check(back.find(path("/P")) == -1, "project keys preserve case on this platform")
  else:
    check(back.find(path("/P")) == 0, "project keys ignore case on this platform")
  let p = back.projects[0]
  check(p.targets == @["claude", "pi"] and p.skills == @["alpha"], "round trip lists")
  check(p.installs.len == 1 and p.installs[0].mode == Copy and
        p.installs[0].files[1] == path("ref/a \"q\".md"), "round trip installs")
  check(p.dirs == @[path("/p/.claude/skills")], "round trip dirs")

  # State written before the Path migration must still load as strings.
  let legacy = """
    {"version":1,"lastCheck":1234,"checkEvery":2592000,"repoRev":"abc","projects":[
      {"root":"/p","global":false,"targets":["claude"],"skills":["alpha"],"installs":[
        {"path":"/p/.claude/skills/alpha","skill":"alpha","mode":"Copy",
         "source":"/s/alpha","files":["SKILL.md"]}],"dirs":["/p/.claude/skills"]}]}
  """
  var ok = false
  let old = parseState(legacy, ok)
  check(ok and old.find(path("/p")) == 0 and
        old.projects[0].installs[0].source == path("/s/alpha") and
        old.projects[0].installs[0].files == @[path("SKILL.md")], "legacy state loads")
  check(readFile($statePath(data)).find("\"data\"") < 0, "paths serialize as JSON strings")

  # A directory at the temporary file path makes opening it fail.
  let saved = readFile($(statePath(data)))
  createDir(data / path("state.json.tmp"))
  s.repoRev = "must not replace abc"
  var failed = false
  try:
    saveState(data, s)
  except ErrorCode:
    failed = true
  check(failed, "temporary state write failure propagates")
  check(readFile($(statePath(data))) == saved, "failed save leaves previous state bytes intact")
  back = loadState(data, corrupt)
  check(not corrupt and back.repoRev == "abc" and back.projects.len == 1,
        "previous state remains readable after failed save")
  removeDir(data / path("state.json.tmp"))

  writeFile($(statePath(data)), "{\"version\": 1, \"projects\": [tru")
  back = loadState(data, corrupt)
  check(corrupt and back.projects.len == 0, "corrupt state starts fresh")
  check(fileExists($(data / path("state.json.bad"))), "corrupt state kept aside")
  check(not fileExists($(statePath(data))), "corrupt state not left in place")

  writeFile($(statePath(data)), "{\"version\": 99}")
  back = loadState(data, corrupt)
  check(corrupt, "unknown schema version is not trusted")

  writeFile($(statePath(data)), "[1]")
  back = loadState(data, corrupt)
  check(corrupt, "non-object document is not trusted")

  var gs = newState()
  check(gs.findGlobal() == -1, "fresh state has no global project")
  gs.projects.add Project(global: true, targets: @["crush"], skills: @["alpha"],
    installs: @[Install(path: path("/home/.config/crush/skills/alpha"), skill: "alpha", mode: Link,
                        source: path("/s/alpha"))],
    dirs: @[path("/home/.config/crush/skills")])
  gs.projects.add Project(root: path("/p"), targets: @["claude"], skills: @["alpha"])
  check(gs.findGlobal() == 0, "findGlobal locates index 0")
  check(gs.find(path("/p")) == 1, "find locates regular project at index 1")
  check(gs.find(path("")) == -1, "find never matches the global entry")
  saveState(data, gs)
  let gback = loadState(data, corrupt)
  check(not corrupt and gback.findGlobal() == 0 and gback.find(path("/p")) == 1,
        "round trip preserves global project and project together")
  check(gback.projects[0].global and not gback.projects[1].global,
        "global flag survives the round trip")

proc testStale() =
  var s = newState()
  let t = 100 * 24 * 3600
  check(isStale(s, t), "never checked is stale")
  s.lastCheck = t - 31 * 24 * 3600
  check(isStale(s, t), "31 days is stale")
  s.lastCheck = t - 24 * 3600
  check(not isStale(s, t), "1 day is current")

proc testRoot(tmp: Path) {.raises.} =
  let proj = tmp / path("proj")
  createDir(proj / path(".git"))
  createDir(proj / path("src") / path("deep"))
  let real = path(expandFilename($proj))
  check(projectRoot(proj / path("src") / path("deep")) == real, "root found from a subdirectory")
  check(projectRoot(proj / path("src") / path("..") / path("src")) == real, "dot-dot normalized")
  createSymlink(proj, tmp / path("alias"))
  check(projectRoot(tmp / path("alias") / path("src")) == real,
    "symlinked path resolves to one key")
  let loose = tmp / path("loose")
  createDir(loose)
  let looseRoot = projectRoot(loose)
  check(looseRoot == path(expandFilename($loose)), "no git: directory itself; got " & $looseRoot &
        ", expected " & $path(expandFilename($loose)) &
        "; fixture requires a temporary parent without a .git ancestor (check TMPDIR)")
  mkfile(tmp / path("wt") / path(".git"), "gitdir: elsewhere")
  createDir(tmp / path("wt") / path("a"))
  check(projectRoot(tmp / path("wt") / path("a")) == path(expandFilename($(tmp / path("wt")))),
    ".git file (worktree)")

  # The nearest enclosing repository wins.
  let inner = proj / path("nested")
  createDir(inner / path("src") / path("deep"))
  check(sh(proj, ["init", "-q"]) == 0 and sh(inner, ["init", "-q"]) == 0,
        "nested local repositories initialized")
  check(projectRoot(inner / path("src") / path("deep")) == path(expandFilename($inner)),
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

proc testCatalog(tmp: Path) {.raises.} =
  let store = tmp / path("store")
  makeStore(store)
  createSymlink(store / path("alpha"), store / path("linked"))
  # A broken directory link must not hide valid catalog entries.
  createSymlink(store / path("missing-skill"), store / path("broken"))
  let skills = discover(store)
  check(skills.names == @["alpha", "beta", "gamma"], "discovery: " & skills.names.join(","))
  check(skills[0].description == "Alpha does things. More text.", "description read")
  check(skills[1].description == "", "missing frontmatter falls back")
  check(skills[2].description == "Folded text", "folded description")
  check(discover(tmp / path("nope")).len == 0, "missing catalog is empty")
  for bad in ["..", "../x", "/etc", "a/b", "a\\b", ".git", "", "-x"]:
    check(not validName(bad), "rejects name " & bad)
  check(validName("nim-testing") and validName("a_b2"), "accepts plain names")

  # Discovery sorts entries by name.
  let unsorted = tmp / path("unsorted-store")
  for name in ["charlie", "alpha", "bravo"]:
    mkfile(unsorted / path(name) / path("SKILL.md"), skillMd(name))
  let ordered = discover(unsorted)
  check(ordered.names == @["alpha", "bravo", "charlie"],
        "discovery sorts deliberately unsorted creation order")
  for s in ordered:
    check(s.description == s.name, "sorted description belongs to directory " & s.name)
  mkfile(unsorted / path("0-first") / path("SKILL.md"), "---\nname: other\n---\n")
  mkfile(unsorted / path("Z-last") / path("SKILL.md"), skillMd("'quoted'"))
  mkfile(unsorted / path("nested") / path("child") / path("SKILL.md"),
    skillMd("not a direct child"))
  let mixed = discover(unsorted)
  check(mixed.names == @["0-first", "Z-last", "alpha", "bravo", "charlie"],
        "discovery keeps directory identity, flat scope and ASCII ordering")
  check(mixed[0].description == "" and mixed[1].description == "quoted",
        "sorted missing and quoted descriptions")
  let unreadable = unsorted / path("bravo") / path("SKILL.md")
  let perms = getFilePermissions(unreadable)
  try:
    setFilePermissions(unreadable, {})
    var denied = false
    try:
      discard readFile($unreadable)
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

proc testInstall(tmp: Path) {.raises.} =
  let store = tmp / path("install-store")
  makeStore(store)
  let root = tmp / path("app")
  createDir(root)
  # Something the user put there themselves.
  mkfile(root / path(".claude") / path("skills") / path("alpha") / path("SKILL.md"),
    "user's own alpha")
  var p = Project(root: root)

  var r = sync(p, store, @[path(".claude/skills"), path(".pi/skills")], @["alpha", "beta"])
  check(r.collisions == @[root / path(".claude/skills/alpha")], "collision reported")
  check(readFile($(root / path(".claude/skills/alpha/SKILL.md"))) == "user's own alpha",
        "unmanaged destination untouched")
  check(r.placed.len == 3 and p.installs.len == 3, "other destinations placed")
  check(symlinkExists(root / path(".pi/skills/beta")), "linked on unix")
  var created: seq[string] = @[]
  for dir in p.dirs: created.add $dir
  check(p.dirs == @[root / path(".pi"), root / path(".pi/skills")],
        "created dirs recorded: " & created.join(","))
  check(missing(p) == 0, "all intact")

  # Deselect beta: its links go, the user's alpha stays.
  r = sync(p, store, @[path(".claude/skills"), path(".pi/skills")], @["alpha"])
  check(r.removed.len == 2 and not taken(root / path(".pi/skills/beta")), "deselected removed")
  check(fileExists($(root / path(".claude/skills/alpha/SKILL.md"))), "unmanaged survives resync")

  # A copy, modified by the user afterwards.
  var q = Project(root: tmp / path("app2"))
  createDir(q.root)
  let script = store / path("alpha") / path("scripts") / path("run.sh")
  mkfile(script, "#!/bin/sh\necho hi\n")
  setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
  # Copies skip source links, including dangling links.
  createSymlink(script, store / path("alpha") / path("file-link"))
  createSymlink(store / path("alpha") / path("references"),
    store / path("alpha") / path("dir-link"))
  let vanished = store / path("alpha") / path("vanished")
  mkfile(vanished, "removed after linking")
  createSymlink(vanished, store / path("alpha") / path("broken-link"))
  check(tryRemoveFile(vanished) == Success, "break source file link")
  r = sync(q, store, @[path(".agents/skills")], @["alpha"], copy = true)
  let copyDir = q.root / path(".agents/skills/alpha")
  check(q.installs.len == 1 and q.installs[0].mode == Copy, "copy mode recorded")
  check(fileExists($(copyDir / path("references/notes.md"))), "copy is recursive")
  check(fpUserExec in getFilePermissions(copyDir / path("scripts/run.sh")),
        "copy keeps the exec bit")
  check(r.failed.len == 0, "source links do not fail copy installation")
  for name in ["file-link", "dir-link", "broken-link"]:
    check(not taken(copyDir / path(name)), "copy skips source " & name)
    check(path(name) notin q.installs[0].files, "source link is not in copy manifest: " & name)
  check(path("dir-link/notes.md") notin q.installs[0].files,
    "copy manifest excludes linked contents")
  writeFile($(copyDir / path("mine.txt")), "user file")

  # Upstream change, then resync of the copy.
  writeFile($(store / path("alpha") / path("SKILL.md")), skillMd("Alpha v2."))
  discard tryRemoveFile(store / path("alpha") / path("references") / path("notes.md"))
  resync(q.installs[0])
  check("Alpha v2." in readFile($(copyDir / path("SKILL.md"))), "copy resynced")
  check(not fileExists($(copyDir / path("references/notes.md"))), "file dropped upstream removed")
  check(fileExists($(copyDir / path("mine.txt"))), "user file survives resync")
  for name in ["file-link", "dir-link", "broken-link"]:
    check(not taken(copyDir / path(name)), "refresh still skips source " & name)

  # Remove everything NYX made in both projects.
  r = removeAll(p)
  check(r.kept.len == 0 and p.installs.len == 0, "links removed")
  check(not dirExists($(root / path(".pi"))), "empty created dirs pruned")
  check(readFile($(root / path(".claude/skills/alpha/SKILL.md"))) == "user's own alpha",
        "remove leaves unmanaged files")
  r = removeAll(q)
  check(r.kept == @[copyDir], "modified copy reported as kept")
  check(fileExists($(copyDir / path("mine.txt"))) and not fileExists($(copyDir / path("SKILL.md"))),
        "only NYX's files removed from a copy")

  # A link the user replaced with their own directory is not NYX's any more.
  var u = Project(root: tmp / path("app3"))
  createDir(u.root)
  discard sync(u, store, @[path(".claude/skills")], @["gamma"])
  let g = u.root / path(".claude/skills/gamma")
  discard tryRemoveFile(g)
  mkfile(g / path("SKILL.md"), "replaced")
  check(missing(u) == 1, "replaced install counts as missing")
  r = removeAll(u)
  check(r.kept == @[g] and readFile($(g / path("SKILL.md"))) == "replaced",
    "replacement left alone")

proc testRetargetedLink(tmp: Path) {.raises.} =
  # A user-retargeted link no longer belongs to NYX.
  let store = tmp / path("retarget-store")
  mkfile(store / path("alpha") / path("SKILL.md"), skillMd("original"))
  let other = tmp / path("user-skill")
  mkfile(other / path("SKILL.md"), "user's target")
  var p = Project(root: tmp / path("retarget-app"))
  discard sync(p, store, @[path(".claude/skills")], @["alpha"])
  let inst = p.installs[0]
  check(tryRemoveFile(inst.path) == Success, "remove original installed link")
  createSymlink(other, inst.path)
  check(missing(p) == 1 and not intact(inst), "retargeted link counts as missing")
  check(not unplace(inst) and expandSymlink(inst.path) == other,
        "removal leaves retargeted link alone")
  let r = sync(p, store, @[path(".claude/skills")], @["alpha"])
  check(r.collisions == @[inst.path] and p.installs.len == 0,
        "resync relinquishes retargeted link and reports collision")
  check(expandSymlink(inst.path) == other and
    readFile($(other / path("SKILL.md"))) == "user's target",
        "resync preserves user link and target")

proc testGlobalInstall(tmp: Path) {.raises.} =
  let store = tmp / path("global-store")
  makeStore(store)
  let home = tmp / path("user-home")
  let cfg = tmp / path("user-cfg")
  createDir(home)
  createDir(cfg)
  var saved: seq[(string, bool, string)] = @[]
  for key in ["XDG_CONFIG_HOME"]:
    saved.add (key, existsEnv(key), getEnv(key))
  putEnv("XDG_CONFIG_HOME", $cfg)
  defer:
    for (key, had, value) in saved:
      if had: putEnv(key, value)
      else: delEnv(key)

  let all = allTargets()
  let crushDir = globalSkillDir(all[byId("crush")], home)
  let claudeDir = globalSkillDir(all[byId("claude")], home)
  check(crushDir == cfg / path("crush/skills"), "global crush dir under XDG")
  check(claudeDir == home / path(".claude/skills"), "global claude dir under home")

  var g = Project(global: true)
  var r = sync(g, store, @[crushDir, claudeDir], @["alpha"])
  check(r.placed.len == 2 and g.installs.len == 2, "global skills installed")
  check(symlinkExists(cfg / path("crush/skills/alpha")), "crush global link exists")
  check(symlinkExists(home / path(".claude/skills/alpha")), "claude global link exists")

  # Project install in another directory
  let projRoot = tmp / path("my-project")
  createDir(projRoot)
  var p = Project(root: projRoot)
  var pr = sync(p, store, @[path(".crush/skills")], @["alpha"])
  check(pr.placed.len == 1 and p.installs.len == 1, "project skill installed")
  check(symlinkExists(projRoot / path(".crush/skills/alpha")), "project link exists")

  # Removing project does not remove global
  let prep = removeAll(p)
  check(prep.removed.len == 1, "project removed")
  check(not symlinkExists(projRoot / path(".crush/skills/alpha")), "project link removed")
  check(symlinkExists(cfg / path("crush/skills/alpha")), "global crush link remains")
  check(symlinkExists(home / path(".claude/skills/alpha")), "global claude link remains")

  # Removing global cleans up global and prunes empty dirs
  let grep = removeAll(g)
  check(grep.removed.len == 2, "global removed")
  check(not symlinkExists(cfg / path("crush/skills/alpha")), "global crush link removed")
  check(not symlinkExists(home / path(".claude/skills/alpha")), "global claude link removed")
  check(not dirExists($(cfg / path("crush"))), "empty crush dir pruned")
  check(not dirExists($(home / path(".claude"))), "empty claude dir pruned")

proc testCliGlobal() {.raises.} =
  let p1 = startProcess("bin/nyx", args = @["-g"], options = {poUsePath, poStdErrToStdOut})
  defer: close(p1)
  check(waitForExit(p1, 5000) != 0, "nyx -g without subcommand fails")

  let p2 = startProcess("bin/nyx", args = @["--global"], options = {poUsePath, poStdErrToStdOut})
  defer: close(p2)
  check(waitForExit(p2, 5000) != 0, "nyx --global without subcommand fails")

proc prompt(mode: string) =
  # Child mode: call the real prompts with pipe-backed stdin/stdout. Keeping
  # this in the test executable avoids compiling a second fixture program.
  if mode == "yes" or mode == "no":
    let answer = confirm("Proceed?", mode == "yes")
    echo "answer=", answer
  else:
    let items = @[Choice(label: "first"), Choice(label: "second"),
                  Choice(label: "third")]
    var sel = @[false, true, false]
    choose(items, sel, minOne = mode == "required")
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

proc testRepo(tmp: Path) {.raises.} =
  var o = ""
  # No access: a repository that is not there.
  let r = repo.clone("file://" & $(tmp / path("missing-repo")), tmp / path("clone0"), o)
  check(r == NoAccess, "missing repository is no access, got " & $r)
  check(not dirExists($(tmp / path("clone0"))), "failed clone leaves nothing")

  # No git at all.
  let hadPath = existsEnv("PATH")
  let oldPath = getEnv("PATH")
  try:
    putEnv("PATH", $(tmp / path("empty-bin")))
    o = "stale output"
    check(pull(tmp, o) == NoGit, "git missing detected")
    check(o.len == 0, "missing git clears output")
  finally:
    if hadPath: putEnv("PATH", oldPath)
    else: delEnv("PATH")

  # Upstream change detection through a real (local) repository.
  let origin = tmp / path("origin")
  makeStore(origin)
  check(sh(origin, ["init", "-q"]) == 0 and sh(origin, ["add", "-A"]) == 0 and
        sh(origin, ["commit", "-q", "-m", "one"]) == 0, "origin repo")
  let clone = tmp / path("clone")
  check(repo.clone($origin, clone, o) == Done, "clone: " & o)
  let before = head(clone)
  writeFile($(origin / path("beta") / path("SKILL.md")), skillMd("Beta v2."))
  check(sh(origin, ["commit", "-q", "-am", "two"]) == 0, "second commit")
  check(pull(clone, o) == Done, "pull: " & o)
  check(changedSkills(clone, before, head(clone)) == @["beta"], "changed skills")
  check(changedSkills(clone, head(clone), head(clone)).len == 0, "no change")

proc testChangedSkills(tmp: Path) {.raises.} =
  let dir = tmp / path("changes")
  mkfile(dir / path("alpha") / path("SKILL.md"), skillMd("Alpha."))
  mkfile(dir / path("alpha") / path("guide.txt"), "unique guide to move between skills\n")
  mkfile(dir / path("alpha") / path("obsolete.txt"), "remove me")
  mkfile(dir / path("beta") / path("SKILL.md"), skillMd("Beta."))
  mkfile(dir / path("README.md"), "one")
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
  mkfile(dir / path("alpha") / path("SKILL.md"), skillMd("Alpha v2."))
  mkfile(dir / path("alpha") / path("nested") / path("notes.txt"), "added")
  removeFile(dir / path("alpha") / path("obsolete.txt"))
  mkfile(dir / path("beta") / path("notes.txt"), "also added")
  mkfile(dir / path("README.md"), "two")
  check(sh(dir, ["add", "-A"]) == 0 and
        sh(dir, ["commit", "-q", "-m", "ordinary changes"]) == 0,
        "ordinary change commit")
  let ordinary = changedSkills(dir, before, head(dir))
  check(ordinary == @["alpha", "beta"],
        "ordinary additions, edits and deletions deduplicate skills: " & ordinary.join(","))

  before = head(dir)
  mkfile(dir / path("delta") / path("café.txt"), "unicode")
  var expected = @["delta"]
  when not defined(windows):
    # These characters are legal filename bytes on POSIX filesystems.
    mkfile(dir / path("beta") / path("tab\tfile.txt"), "tab")
    mkfile(dir / path("beta") / path("line\nbreak.txt"), "newline")
    mkfile(dir / path("gamma") / path("double\"quote.txt"), "quote")
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
  mkfile(dir / path("README.md"), "root-only change")
  check(sh(dir, ["commit", "-q", "-am", "root only"]) == 0, "root-only commit")
  check(changedSkills(dir, before, head(dir)).len == 0, "root files are not skills")
  check(changedSkills(dir, "not-a-revision", head(dir)).len == 0,
        "failed diff keeps the empty-result policy")

proc testGit(tmp: Path) {.raises.} =
  # Do not inherit repository selection, injected config, identities, signing,
  # URL rewrites, hooks or templates from the caller. Snapshot before deleting:
  # envPairs iterates storage that delEnv modifies.
  var saved: seq[(string, string)] = @[]
  for key, value in envPairs():
    if key.startsWith("GIT_") or key == "LC_ALL": saved.add (key, value)
  try:
    for (key, value) in saved: delEnv(key)
    let config = tmp / path("gitconfig")
    let empty = tmp / path("empty-git")
    createDir(empty)
    writeFile($config, "")
    putEnv("GIT_CONFIG_NOSYSTEM", "1")
    putEnv("GIT_CONFIG_GLOBAL", $config)
    putEnv("GIT_CONFIG_COUNT", "4")
    for i, (key, value) in [("init.defaultBranch", "main"),
        ("init.templateDir", $empty), ("core.hooksPath", $empty),
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
  var tmp = path("")
  try:
    tmp = createTempDir("nyx-test-", "")
    {.cast(assumeSync).}:
      failures += testPaths()
      failures += testFirstLine()
    testState(tmp)
    testTargets(tmp)
    testStale()
    testDescription()
    testNames()
    testCatalog(tmp)
    testInstall(tmp)
    testGlobalInstall(tmp)
    testRetargetedLink(tmp)
    testPrompts()
    testCliGlobal()
    testGit(tmp)
  except ErrorCode as e:
    fail("raised " & $e)
  try:
    if tmp != path(""): removeDir(tmp)
  except ErrorCode as e:
    fail("cleanup raised " & $e)
  check(tmp == path("") or not dirExists($tmp), "temporary fixture removed")
  {.cast(assumeSync).}:
    if failures > 0:
      echo failures, " failed"
      quit(1)
  echo "all tests passed"

main()
