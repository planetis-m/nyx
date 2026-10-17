## nyx: installs coding-agent skills from the skills repository into the
## current project, and keeps them up to date.

import std/[appdirs, paths, syncio, strutils, os, dirs, smartcli]
import state, targets, catalog, repo, install, ui

type
  Ctx = object
    data: Path     ## NYX data directory
    root: Path     ## canonical project root; unset when `global`
    global: bool   ## user-level skill directories instead of the project
    st: State
    corrupt: bool  ## state.json was unreadable and set aside

# --- helpers ----------------------------------------------------------------

proc display(file: Path): string =
  ## `file` with the home directory shortened to `~`.
  let p = $file
  var home = $appdirs.getHomeDir()
  while home.len > 1 and home[^1] in {DirSep, AltSep} and
      not (home.len == 3 and home[1] == ':'):
    home.setLen(home.len - 1)
  if p == home: return "~"
  # Keep the separator in ~/child when home itself is a filesystem root.
  let n = if home.len > 0 and home[^1] in {DirSep, AltSep}: home.len - 1 else: home.len
  if home.len > 0 and p.len > home.len and p.startsWith(home) and p[n] in {DirSep, AltSep}:
    "~" & p.substr(n)
  else: p

proc rel(c: Ctx; file: Path): string =
  let p = $file
  let root = $c.root
  let n = root.len
  if n == 0 or p.len <= n or not p.startsWith(root): return p
  if root[^1] in {DirSep, AltSep}: p.substr(n)
  elif p[n] in {DirSep, AltSep}: p.substr(n + 1)
  else: p

proc shown(c: Ctx; file: Path): string =
  ## A path as the command reports it: relative to the project, or to `~`.
  if c.global: display(file) else: c.rel(file)

proc scope(c: Ctx): string =
  if c.global: "user scope" else: "project"

proc ago(t: int): string =
  if t == 0: return "never"
  let hours = (now() - t) div 3600
  if hours < 1: "just now"
  elif hours < 24: $hours & "h ago"
  elif hours < 48: "1 day ago"
  else: $(hours div 24) & " days ago"

proc short(s: string; n: int): string =
  ## First sentence of `s`, cut on a word boundary to at most `n` chars.
  result = s
  let stop = result.find('.')
  if stop > 0: result = result.substr(0, stop - 1)
  if result.len > n:
    var cut = n
    while cut > 0 and result[cut] != ' ': dec cut
    result = result.substr(0, (if cut > 0: cut else: n) - 1)

proc save(c: Ctx) =
  try:
    saveState(c.data, c.st)
  except:
    fail "cannot write " & $statePath(c.data)
    quit(1)

proc context(global = false): Ctx =
  result = Ctx(data: dataDir(), global: global)
  if global:
    if appdirs.getHomeDir() == path(""):
      fail "cannot resolve the home directory"
      quit(1)
  else:
    try:
      result.root = projectRoot(path("."))
    except:
      fail "cannot resolve the current directory"
      quit(1)
  let loaded = loadState(result.data)
  result.st = loaded.state
  result.corrupt = loaded.corrupt

proc notes(c: Ctx) =
  if c.corrupt:
    warn "state was unreadable, starting fresh" & dim("  (kept as state.json.bad)")

proc project(c: Ctx): int =
  if c.global: c.st.findGlobal() else: c.st.find(c.root)

proc skillDirs(c: Ctx; ids: seq[string]): seq[Path] =
  if c.global: globalSkillDirs(ids, appdirs.getHomeDir()) else: skillDirs(ids)

proc targetNames(ids: seq[string]): string =
  var names: seq[string] = @[]
  for id in ids:
    let i = byId(id)
    if i >= 0: names.add Targets[i].name
  result = names.join(", ")

# --- updating ---------------------------------------------------------------

proc firstLine(output: string): string =
  ## First line of `output`, without surrounding blank space; "" when empty.
  result = ""
  for line in output.strip().splitLines():
    return line

proc explain(r: GitResult; output: string; setup: bool) =
  case r
  of Done: discard
  of NoGit:
    fail "git not found" & dim("  nyx uses git to fetch skills")
  of NoAccess:
    warn "no access to the skills repository"
    if setup: line "    " & dim("check your GitHub login, e.g. gh auth status")
    else: line "    " & dim("installed skills stay; updates unavailable")
  of Offline:
    warn "offline" & dim("  installed skills stay; try again later")
  of Failed:
    fail "git failed"
    let message = firstLine(output)
    if message.len > 0: line "    " & dim(message)

proc refresh(c: var Ctx; setup = false): bool =
  ## Clone or fast-forward the skills repository, then bring copied installs
  ## in every project up to date. Records the check time either way.
  let store = skillsDir(c.data)
  let before = discover(store).names
  let fresh = not dirExists($store)
  let oldRev = c.st.repoRev
  var output = ""
  var r = Done
  if fresh:
    try:
      createDir(c.data)
    except:
      fail "cannot create " & $c.data
      quit(1)
    r = repo.clone(repoUrl(), store, output)
  else:
    r = pull(store, output)
  c.st.lastCheck = now()
  if r != Done:
    explain(r, output, setup)
    save(c)
    return false

  let newRev = head(store)
  let changed = changedSkills(store, oldRev, newRev)
  # An absent revision or unavailable diff cannot establish what was applied.
  # Recopy conservatively; an unchanged, known revision needs no work.
  let all = oldRev.len == 0 or newRev.len == 0 or
    (oldRev != newRev and changed.len == 0)
  let after = discover(store)
  var complete = true
  for p in mitems(c.st.projects):
    for inst in mitems(p.installs):
      if all or inst.skill in changed:
        try:
          resync(inst)
        except:
          complete = false
          warn "could not refresh " & display(inst.path)
  if complete and newRev.len > 0: c.st.repoRev = newRev
  save(c)

  if fresh:
    done("skills", $after.len & " available")
  else:
    var updated: seq[string] = @[]
    var added = 0
    for s in after:
      if s.name notin before: inc added
      elif s.name in changed: updated.add s.name
    var summary = $updated.len & " updated, " &
      $(after.len - updated.len - added) & " current"
    if added > 0: summary.add ", " & $added & " new"
    done("skills", summary)
    for name in updated: done(name, "updated")
  result = true

# --- selection ---------------------------------------------------------------

proc pickTargets(c: Ctx; p: Project; configured: bool): seq[string] =
  let home = appdirs.getHomeDir()
  var items: seq[Choice] = @[]
  var sel: seq[bool] = @[]
  for t in Targets:
    let detail = if c.global: display(globalSkillDir(t, home)) else: $t.skillDir
    items.add Choice(label: t.name, detail: detail)
    sel.add(if configured: t.id in p.targets else: detect(t, p.root, home))
  choose(items, sel, minOne = true)
  result = @[]
  for i in 0..<Targets.len:
    if sel[i]: result.add Targets[i].id

proc pickSkills(skills: seq[Skill]; chosen: seq[string]): seq[string] =
  var items: seq[Choice] = @[]
  var sel: seq[bool] = @[]
  for s in skills:
    items.add Choice(label: s.name, detail: short(s.description, 60))
    sel.add(s.name in chosen)
  choose(items, sel, minOne = true)
  result = @[]
  for i in 0..<skills.len:
    if sel[i]: result.add skills[i].name

# --- commands ----------------------------------------------------------------

proc wizard(c: var Ctx) =
  splash()
  notes(c)
  if c.global:
    field "scope", White & "user"
  else:
    field "project", White & display(c.root)
  line()

  let store = skillsDir(c.data)
  if not dirExists($store):
    line "  " & dim("nyx needs access to the skills repository")
    if not refresh(c, setup = true):
      line()
      quit(1)
    line()
  let skills = discover(store)
  if skills.len == 0:
    fail "no skills found in " & display(store)
    quit(1)

  let idx = project(c)
  var p = if idx >= 0: c.st.projects[idx]
          else: Project(root: c.root, global: c.global)

  heading "targets"
  let ids = pickTargets(c, p, configured = idx >= 0)
  line()

  heading "skills"
  let chosen = pickSkills(skills, p.skills)
  line()

  field "targets", targetNames(ids)
  field "skills", $chosen.len
  line()
  if not confirm("install?", true):
    line "  " & dim("nothing changed")
    line()
    return
  line()

  p.targets = ids
  p.skills = chosen
  let dirs = skillDirs(c, ids)
  let rep = sync(p, store, dirs, chosen)
  for s in chosen:
    var links = 0
    var copies = 0
    for inst in p.installs:
      if inst.skill == s:
        if inst.mode == Link: inc links else: inc copies
    if links + copies > 0:
      let how = if copies == 0: "linked" elif links == 0: "copied" else: "placed"
      done(s, how & " -> " & $(links + copies) & " targets")
  for d in rep.removed:
    line "  " & Blood & "- " & Reset & alignLeft(shown(c, d), 22) & "  " & dim("removed")
  for d in rep.collisions: warn shown(c, d) & dim("  exists, not nyx's; left alone")
  for d in rep.kept: warn shown(c, d) & dim("  modified; left alone")
  for d in rep.failed: fail shown(c, d) & dim("  could not install")

  if idx >= 0: c.st.projects[idx] = p
  else: c.st.projects.add p
  save(c)
  line()
  line "  " & Bold & Gold & "ready" & Reset &
    dim("  " & $chosen.len & " skills on " & $dirs.len & " targets")
  line()

proc status(c: var Ctx) =
  banner()
  notes(c)
  let p = c.st.projects[project(c)]
  field "project", White & display(c.root)
  field "targets", targetNames(p.targets)
  let gone = missing(p)
  field "skills", $p.skills.len & " installed" &
    (if gone > 0: Ember & "  " & $gone & " missing, run nyx setup" else: "")
  field "checked", ago(c.st.lastCheck)
  if isStale(c.st, now()):
    line()
    if refresh(c): field "state", Gold & "current"
  else:
    field "state", Gold & "current"
  line()

proc update(c: var Ctx) =
  banner()
  notes(c)
  discard refresh(c)
  line()

proc remove(c: var Ctx) =
  banner()
  notes(c)
  let idx = project(c)
  if idx < 0:
    line "  " & dim(if c.global: "nothing to remove in user scope" else: "nothing to remove here")
    line()
    return
  var p = c.st.projects[idx]
  # One line per agent directory, as in the wizard.
  var dirs: seq[Path] = @[]
  for inst in p.installs:
    let d = parentDir(inst.path)
    if d notin dirs: dirs.add d
  for d in dirs:
    var n = 0
    for inst in p.installs:
      if parentDir(inst.path) == d: inc n
    line "  " & Blood & "- " & Bone & alignLeft(shown(c, d), 22) & "  " & dim($n & " skills")
  line "  " & Blood & "- " & Bone & alignLeft("nyx record", 22) & "  " & dim(if c.global: "user state" else: "project state")
  line()
  if not confirm("remove " & $p.skills.len & " skills from " & $dirs.len & " targets?", false):
    line "  " & dim("kept")
    line()
    return
  line()
  let rep = removeAll(p)
  c.st.projects.delete(idx)
  save(c)
  done("removed", $rep.removed.len & " installs")
  for d in rep.kept: warn shown(c, d) & dim("  modified; left alone")
  line()
  line "  " & Bold & Blood & "gone" & Reset &
    (if rep.kept.len == 0: dim("  " & scope(c) & " is clean") else: "")
  line()

proc main() =
  if smartcli.paramCount() == 0:
    var c = context()
    if project(c) >= 0: status(c) else: wizard(c)
    return
  let opts = cliapp("""nyx - skills for your coding agents

Usage: nyx [setup|update|remove] [-g]

  Run `nyx` alone to set up this project, or to see its status.

Commands:
  setup   Set up or reconfigure this project (with -g, user scope)
  update  Update skills everywhere nyx installed them
  remove  Remove nyx from this project (with -g, user scope)

Options:
  -g, --global  Use user-level skill directories instead of this project
  -h, --help    Show this help
""")
  var c = context(opts.global)
  case opts.command
  of cmdSetup: wizard(c)
  of cmdUpdate: update(c)
  of cmdRemove: remove(c)
  else: discard

when isMainModule:
  main()
