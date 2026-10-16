# nyx

Installs coding-agent skills from a skills repository into the current project, and keeps them up to date.

Skills are cloned once into nyx's data directory. Each project gets symlinks (or copies, where symlinks are unavailable) into its agent skill directories, so one clone serves every project and updates are a fast-forward away.

## Requirements

- [Nimony](https://github.com/nim-lang/nimony) 0.6.3 or newer
- `git`
- access to the skills repository (default: `https://github.com/planetis-m/skills`)

## Build

```sh
nimony c -o:bin/nyx src/nyx.nim
```

## Usage

```sh
nyx          # set up this project, or show its status if already set up
nyx setup    # set up or reconfigure this project
nyx update   # update skills now
nyx remove   # remove nyx from this project
nyx -h       # help
```

Run `nyx` in a repository root. The project is keyed by the nearest enclosing directory holding a `.git` entry.

## Targets

Skills land in `<project>/<skillDir>/<skill>` for each selected target. Only detected targets start ticked in the wizard. Targets sharing a skill directory install each skill once.

| Skill directory | Targets |
| --- | --- |
| `.agents/skills` | Codex, Agents, Cursor, OpenCode, Gemini CLI, GitHub Copilot, Amp, Cline |
| `.claude/skills` | Claude Code |
| `.crush/skills` | Crush |
| `.pi/skills` | Pi |
| `.windsurf/skills` | Windsurf |
| `.roo/skills` | Roo Code |
| `.continue/skills` | Continue |
| `.goose/skills` | Goose |

Detection honors `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and `XDG_CONFIG_HOME` for the tools that use them.

## Files

State lives in the platform data directory (`~/.local/share/nyx` on Linux) or wherever `NYX_HOME` points:

- `state.json` - what nyx manages, per project. Written by temporary file plus rename; unreadable state is set aside as `state.json.bad`.
- `skills/` - the git clone of the skills repository.

## Environment

| Variable | Effect |
| --- | --- |
| `NYX_REPO` | Use another skills repository. |
| `NYX_HOME` | Use another data directory. |

## Safety

- An existing destination that nyx did not create is a collision: it is reported and never touched.
- Removal only acts on recorded installs that still look like what nyx made; skills a user edited are left alone, and copy installs are removed file by file so added files survive.
- The skills clone is only ever fast-forwarded, never reset or merged.
- Git never prompts for credentials; missing access or a network failure leaves installed skills in place.

Updates are checked lazily at most once every 30 days whenever `nyx` is run.

## Tests

```sh
tests/run
```

Each test runs in a fresh temporary directory against local git repositories, so no network is needed.
