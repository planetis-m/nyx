## Coding agents NYX can install skills for.
##
## Every target is offered in the wizard; detection only decides whether it
## starts ticked. NYX creates a target's skill directory only after the user
## selects that target, never just because it knows about it.
##
## Detection checks project markers, home markers, and executables on PATH.
## Each target's paths and markers are defined in `allTargets` below.
## Targets sharing `.agents/skills` install each skill once.

import std/[paths, os, envvars, strutils]

type
  Target* = object
    id*: string              ## stable key, stored in state
    name*: string            ## shown in the wizard
    skillDir*: Path  ## project-relative skill directory
    globalDir*: Path  ## home-relative skill directory (unused for now)
    markers: seq[Path]  ## project-relative paths that mean "in use"
    homeMarkers: seq[Path]  ## home-relative paths that mean "installed"
    homeEnv: string          ## environment override for the config directory
    envDir: Path  ## tool directory within a shared config root
    exe: string              ## executable that means "installed"

proc allTargets*(): seq[Target] =
  @[Target(id: "claude", name: "Claude Code", skillDir: path(".claude/skills"),
      globalDir: path(".claude/skills"), markers: @[path(".claude"), path("CLAUDE.md")],
      homeMarkers: @[path(".claude")], homeEnv: "CLAUDE_CONFIG_DIR", exe: "claude"),
    Target(id: "codex", name: "Codex", skillDir: path(".agents/skills"),
      globalDir: path(".agents/skills"), markers: @[path(".codex")],
      homeMarkers: @[path(".codex")], homeEnv: "CODEX_HOME", exe: "codex"),
    Target(id: "agents", name: "Agents", skillDir: path(".agents/skills"),
      globalDir: path(".agents/skills"), markers: @[path(".agents")]),
    Target(id: "crush", name: "Crush", skillDir: path(".crush/skills"),
      globalDir: path(".config/crush/skills"), markers: @[path(".crush"), path("CRUSH.md")],
      homeMarkers: @[path(".config/crush")], homeEnv: "XDG_CONFIG_HOME", envDir: path("crush"),
      exe: "crush"),
    Target(id: "pi", name: "Pi", skillDir: path(".pi/skills"),
      globalDir: path(".pi/agent/skills"), markers: @[path(".pi")],
      homeMarkers: @[path(".pi")], exe: "pi"),
    Target(id: "cursor", name: "Cursor", skillDir: path(".agents/skills"),
      globalDir: path(".cursor/skills"), markers: @[path(".cursor")],
      homeMarkers: @[path(".cursor")], exe: "cursor"),
    Target(id: "opencode", name: "OpenCode", skillDir: path(".agents/skills"),
      globalDir: path(".config/opencode/skills"),
      markers: @[path(".opencode"), path("opencode.json"), path("opencode.jsonc")],
      homeMarkers: @[path(".config/opencode")], homeEnv: "XDG_CONFIG_HOME",
        envDir: path("opencode"),
      exe: "opencode"),
    Target(id: "gemini", name: "Gemini CLI", skillDir: path(".agents/skills"),
      globalDir: path(".gemini/skills"), markers: @[path(".gemini"), path("GEMINI.md")],
      homeMarkers: @[path(".gemini")], exe: "gemini"),
    Target(id: "copilot", name: "GitHub Copilot", skillDir: path(".agents/skills"),
      globalDir: path(".copilot/skills"), markers: @[path(".github/skills"),
        path(".github/copilot-instructions.md")],
      homeMarkers: @[path(".copilot")], exe: "copilot"),
    Target(id: "windsurf", name: "Windsurf", skillDir: path(".windsurf/skills"),
      globalDir: path(".codeium/windsurf/skills"), markers: @[path(".windsurf"),
        path(".windsurfrules")],
      homeMarkers: @[path(".codeium/windsurf")], exe: "windsurf"),
    Target(id: "roo", name: "Roo Code", skillDir: path(".roo/skills"),
      globalDir: path(".roo/skills"), markers: @[path(".roo"), path(".roomodes")],
        homeMarkers: @[path(".roo")]),
    Target(id: "continue", name: "Continue", skillDir: path(".continue/skills"),
      globalDir: path(".continue/skills"), markers: @[path(".continue")],
      homeMarkers: @[path(".continue")], exe: "cn"),
    Target(id: "goose", name: "Goose", skillDir: path(".goose/skills"),
      globalDir: path(".config/goose/skills"), markers: @[path(".goose"), path(".goosehints")],
      homeMarkers: @[path(".config/goose")], homeEnv: "XDG_CONFIG_HOME", envDir: path("goose"),
      exe: "goose"),
    Target(id: "amp", name: "Amp", skillDir: path(".agents/skills"),
      globalDir: path(".config/agents/skills"), markers: @[path(".amp")],
      homeMarkers: @[path(".config/amp")], homeEnv: "XDG_CONFIG_HOME", envDir: path("amp"),
        exe: "amp"),
    Target(id: "cline", name: "Cline", skillDir: path(".agents/skills"),
      globalDir: path(".agents/skills"), markers: @[path(".cline"), path(".clinerules")],
      homeMarkers: @[path(".cline")], exe: "cline")]

proc exists(p: Path): bool = dirExists($p) or fileExists($p)

proc detect*(t: Target; root, home: Path): bool =
  ## Is this agent in use in `root`, or installed for the user at `home`?
  for m in t.markers:
    if exists(root / m): return true
  let config = if t.homeEnv.len > 0: getEnv(t.homeEnv).strip() else: ""
  if config.len > 0:
    if exists(path(config) / t.envDir): return true
  elif home != path(""):
    for m in t.homeMarkers:
      if exists(home / m): return true
  result = t.exe.len > 0 and findExe(t.exe).len > 0

proc byId*(id: string): int =
  ## Index into `allTargets()`, or -1.
  let all = allTargets()
  result = -1
  for i in 0 ..< all.len:
    if all[i].id == id: return i

proc skillDirs*(ids: seq[string]): seq[Path] =
  ## Distinct project skill directories for the selected target ids.
  result = @[]
  let all = allTargets()
  for id in ids:
    let i = byId(id)
    if i >= 0 and all[i].skillDir notin result: result.add all[i].skillDir
