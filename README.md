# nyx

Installs coding-agent skills from a skills repository into the current project, and keeps them up to date.

Skills are cloned once into nyx's data directory. Each project gets symlinks (or copies, where symlinks are unavailable) into its agent skill directories, so one clone serves every project and updates are a fast-forward away.

## Install

Linux and macOS (installs to `~/.local/bin`):

```sh
curl -fsSL https://github.com/planetis-m/nyx/releases/latest/download/install.sh | sh
```

Windows (PowerShell; installs to `%LOCALAPPDATA%\Programs\nyx` and adds it to the user `PATH`):

```powershell
irm https://github.com/planetis-m/nyx/releases/latest/download/install.ps1 | iex
```

The scripts pick the archive for your OS and architecture, verify it against the release's `SHA256SUMS`, and install the single `nyx` binary. Set `NYX_VERSION` to a tag such as `v0.1.0` to install a specific release, or `NYX_INSTALL_DIR` to install elsewhere.

Release builds exist for Linux x86_64 and ARM64, macOS ARM64, and Windows x86_64. Nimony's native backend has no macOS x86_64 or Windows ARM64 target; on those, build from source.

## Requirements

- `git`
- access to the skills repository (default: `https://github.com/planetis-m/skills`)
- to build: [Nimony](https://github.com/nim-lang/nimony) 0.6.3 or newer

## Build

```sh
nimony c -o:bin/nyx src/nyx.nim
```

Release binaries are built with the native backend (`nimony n -d:release -o:bin/nyx src/nyx.nim`) by `.github/workflows/release.yml` whenever a `v*` tag is pushed.

## Usage

```sh
nyx             # set up this project, or show its status if already set up
nyx setup       # set up or reconfigure this project
nyx update      # update skills in every project and the user scope
nyx remove      # remove nyx from this project
nyx setup -g    # set up or reconfigure user-level skill directories
nyx remove -g   # remove nyx from user-level skill directories
nyx -h          # help
```

Run `nyx` in a repository root. The project is keyed by the nearest enclosing directory holding a `.git` entry. Pass `-g` or `--global` to work on the user's home skill directories instead of this project.

## Targets

Skills land in `<project>/<skillDir>/<skill>` for each selected target. Only detected targets start ticked in the wizard. Targets sharing a skill directory install each skill once.

| Skill directory | Targets |
| --- | --- |
| `.agents/skills` | Codex, Agents, Cursor, OpenCode, Antigravity, GitHub Copilot, Amp, Goose |
| `.claude/skills` | Claude Code |
| `.cline/skills` | Cline |
| `.crush/skills` | Crush |
| `.devin/skills` | Windsurf |
| `.pi/skills` | Pi |
| `.roo/skills` | Roo Code |
| `.continue/skills` | Continue |

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
