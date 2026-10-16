## Coding agents NYX can install skills for.
##
## Every target is offered in the wizard; detection only decides whether it
## starts ticked. NYX creates a target's skill directory only after the user
## selects that target, never just because it knows about it.
##
## Detection checks project markers, home markers, and executables on PATH.
## Each target's paths and markers are defined in `allTargets` below.
## Codex and Agents share `.agents/skills`; selecting both installs once.

import std/os

type
  Target* = object
    id*: string              ## stable key, stored in state
    name*: string            ## shown in the wizard
    skillDir*: string        ## project-relative skill directory
    globalDir*: string       ## home-relative skill directory (unused for now)
    markers: seq[string]     ## project-relative paths that mean "in use"
    homeMarkers: seq[string] ## home-relative paths that mean "installed"
    exe: string              ## executable that means "installed"

proc allTargets*(): seq[Target] =
  @[Target(id: "claude", name: "Claude Code", skillDir: ".claude/skills",
      globalDir: ".claude/skills", markers: @[".claude", "CLAUDE.md"],
      homeMarkers: @[".claude"], exe: "claude"),
    Target(id: "codex", name: "Codex", skillDir: ".agents/skills",
      globalDir: ".agents/skills", markers: @[".codex"],
      homeMarkers: @[".codex"], exe: "codex"),
    Target(id: "agents", name: "Agents", skillDir: ".agents/skills",
      globalDir: ".agents/skills", markers: @[".agents"]),
    Target(id: "crush", name: "Crush", skillDir: ".crush/skills",
      globalDir: ".config/crush/skills", markers: @[".crush", "CRUSH.md"],
      homeMarkers: @[".config/crush"], exe: "crush"),
    Target(id: "pi", name: "Pi", skillDir: ".pi/skills",
      globalDir: ".pi/agent/skills", markers: @[".pi"],
      homeMarkers: @[".pi"], exe: "pi")]

proc exists(p: string): bool = dirExists(p) or fileExists(p)

proc detect*(t: Target; root, home: string): bool =
  ## Is this agent in use in `root`, or installed for the user at `home`?
  for m in t.markers:
    if exists(root / m): return true
  if home.len > 0:
    for m in t.homeMarkers:
      if exists(home / m): return true
  result = t.exe.len > 0 and findExe(t.exe).len > 0

proc byId*(id: string): int =
  ## Index into `allTargets()`, or -1.
  let all = allTargets()
  result = -1
  for i in 0 ..< all.len:
    if all[i].id == id: return i

proc skillDirs*(ids: seq[string]): seq[string] =
  ## Distinct project skill directories for the selected target ids.
  result = @[]
  let all = allTargets()
  for id in ids:
    let i = byId(id)
    if i >= 0 and all[i].skillDir notin result: result.add all[i].skillDir
