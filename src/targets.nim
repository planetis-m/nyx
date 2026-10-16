## Coding agents NYX can install skills for.
##
## Every target is offered in the wizard; detection only decides whether it
## starts ticked. NYX creates a target's skill directory only after the user
## selects that target, never just because it knows about it.
##
## Detection checks project markers, home markers, and executables on PATH.
## Each target's paths and markers are defined in `allTargets` below.
## Targets sharing `.agents/skills` install each skill once.

import std/[os, envvars, strutils]

type
  Target* = object
    id*: string              ## stable key, stored in state
    name*: string            ## shown in the wizard
    skillDir*: string        ## project-relative skill directory
    globalDir*: string       ## home-relative skill directory (unused for now)
    markers: seq[string]     ## project-relative paths that mean "in use"
    homeMarkers: seq[string] ## home-relative paths that mean "installed"
    homeEnv: string          ## environment override for the config directory
    envDir: string           ## tool directory within a shared config root
    exe: string              ## executable that means "installed"

proc allTargets*(): seq[Target] =
  @[Target(id: "claude", name: "Claude Code", skillDir: ".claude/skills",
      globalDir: ".claude/skills", markers: @[".claude", "CLAUDE.md"],
      homeMarkers: @[".claude"], homeEnv: "CLAUDE_CONFIG_DIR", exe: "claude"),
    Target(id: "codex", name: "Codex", skillDir: ".agents/skills",
      globalDir: ".agents/skills", markers: @[".codex"],
      homeMarkers: @[".codex"], homeEnv: "CODEX_HOME", exe: "codex"),
    Target(id: "agents", name: "Agents", skillDir: ".agents/skills",
      globalDir: ".agents/skills", markers: @[".agents"]),
    Target(id: "crush", name: "Crush", skillDir: ".crush/skills",
      globalDir: ".config/crush/skills", markers: @[".crush", "CRUSH.md"],
      homeMarkers: @[".config/crush"], homeEnv: "XDG_CONFIG_HOME", envDir: "crush",
      exe: "crush"),
    Target(id: "pi", name: "Pi", skillDir: ".pi/skills",
      globalDir: ".pi/agent/skills", markers: @[".pi"],
      homeMarkers: @[".pi"], exe: "pi"),
    Target(id: "cursor", name: "Cursor", skillDir: ".agents/skills",
      globalDir: ".cursor/skills", markers: @[".cursor"],
      homeMarkers: @[".cursor"], exe: "cursor"),
    Target(id: "opencode", name: "OpenCode", skillDir: ".agents/skills",
      globalDir: ".config/opencode/skills",
      markers: @[".opencode", "opencode.json", "opencode.jsonc"],
      homeMarkers: @[".config/opencode"], homeEnv: "XDG_CONFIG_HOME", envDir: "opencode",
      exe: "opencode"),
    Target(id: "gemini", name: "Gemini CLI", skillDir: ".agents/skills",
      globalDir: ".gemini/skills", markers: @[".gemini", "GEMINI.md"],
      homeMarkers: @[".gemini"], exe: "gemini"),
    Target(id: "copilot", name: "GitHub Copilot", skillDir: ".agents/skills",
      globalDir: ".copilot/skills", markers: @[".github/skills", ".github/copilot-instructions.md"],
      homeMarkers: @[".copilot"], exe: "copilot"),
    Target(id: "windsurf", name: "Windsurf", skillDir: ".windsurf/skills",
      globalDir: ".codeium/windsurf/skills", markers: @[".windsurf", ".windsurfrules"],
      homeMarkers: @[".codeium/windsurf"], exe: "windsurf"),
    Target(id: "roo", name: "Roo Code", skillDir: ".roo/skills",
      globalDir: ".roo/skills", markers: @[".roo", ".roomodes"], homeMarkers: @[".roo"]),
    Target(id: "continue", name: "Continue", skillDir: ".continue/skills",
      globalDir: ".continue/skills", markers: @[".continue"],
      homeMarkers: @[".continue"], exe: "cn"),
    Target(id: "goose", name: "Goose", skillDir: ".goose/skills",
      globalDir: ".config/goose/skills", markers: @[".goose", ".goosehints"],
      homeMarkers: @[".config/goose"], homeEnv: "XDG_CONFIG_HOME", envDir: "goose",
      exe: "goose"),
    Target(id: "amp", name: "Amp", skillDir: ".agents/skills",
      globalDir: ".config/agents/skills", markers: @[".amp"],
      homeMarkers: @[".config/amp"], homeEnv: "XDG_CONFIG_HOME", envDir: "amp", exe: "amp"),
    Target(id: "cline", name: "Cline", skillDir: ".agents/skills",
      globalDir: ".agents/skills", markers: @[".cline", ".clinerules"],
      homeMarkers: @[".cline"], exe: "cline")]

proc exists(p: string): bool = dirExists(p) or fileExists(p)

proc detect*(t: Target; root, home: string): bool =
  ## Is this agent in use in `root`, or installed for the user at `home`?
  for m in t.markers:
    if exists(root / m): return true
  let config = if t.homeEnv.len > 0: getEnv(t.homeEnv).strip() else: ""
  if config.len > 0:
    if exists(config / t.envDir): return true
  elif home.len > 0:
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
