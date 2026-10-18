# ASF Manager

A one-line installer and TUI (terminal UI) manager for [ArchiSteamFarm](https://github.com/JustArchiNET/ArchiSteamFarm) on Linux containers: **Termux (proot Ubuntu), Ubuntu, Debian**.

It downloads the generic ASF package through a GitHub acceleration mirror, manages a project-local .NET runtime on demand, and provides an interactive menu for day-to-day operations.

## Features

- **One-line install** - `curl ... | bash`, no pre-existing files required
- **Universal architecture** - the same installer serves arm64 and x64
- **On-demand runtime** - the .NET runtime required by ASF is downloaded automatically (the version is read from `ArchiSteamFarm.runtimeconfig.json`); deleting it simply causes a re-download on the next start
- **Runtime management** - download / remove / re-download the full runtime from the TUI
- **Start / Stop** - dynamic menu text reflects the current ASF state
- **Live log** - streams the latest ASF log, with `Press ESC to exit live log` pinned to the bottom of the terminal
- **Update check** - compares the local `version.txt` against the one published on your GitHub release page
- **Multi-account management** - a simple TUI for many bots, plus raw JSON editing; configs are written in the format ASF expects
- **Farm mode switch** - toggle between automatic card farming and play-only mode (specific APPIDs, no badge-page checks)
- **`!play` support** - play-only mode injects the `play` command into ASF's console (equivalent to typing `!play`), bypassing the badge page; it is applied to play-only mode only, so card farming is never affected

## Supported environments

| Environment | Notes |
|---|---|
| Termux (proot Ubuntu) | arm64 on typical phones |
| Ubuntu | x64 / arm64 |
| Debian | x64 / arm64 |

## One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/install.sh | bash
```

The script validates the OS, installs missing tools (curl, unzip, python3, ncurses via apt), downloads ASF generic, installs the required .NET runtime, and writes the manager plus a default global config.

### Optional environment variables

| Variable | Default | Meaning |
|---|---|---|
| `ASF_VERSION` | `6.3.10.6` | ASF release tag to install |
| `MIRROR` | `https://ghfast.top/` | GitHub acceleration prefix used for every GitHub download |
| `ASF_HOME` | `$HOME/.asf` | Installation root |
| `REPO_RAW` | (packaging placeholder) | Raw base URL of this repository |

## Usage

```bash
~/.asf/asf-manager.sh
```

Main menu:

1. **Start / Stop ArchiSteamFarm** - the label toggles based on the running state
2. **Manage Runtime** - shows the version ASF requires vs. the installed one; download / remove / re-download
3. **Live Log** - streams the newest ASF log file; press `ESC` to exit
4. **Update Project** - compares `version.txt` with the release version file and offers to replace the manager
5. **Account Config** - add / edit / delete bots; each bot can also be edited as raw JSON with your `$EDITOR`; ASF hot-reloads config changes
6. **Farm Mode Switch** - per bot: auto card farming, or play-only with a comma-separated APPID list (e.g. `730,570`)

## How play-only mode works

ASF has no `!play` configuration field. `play` is a runtime command (prefix `!` by default, e.g. `!play <bot> <appids>`). Play-only mode therefore:

1. Writes `FarmingPausedByDefault: true` into the bot config (the automatic card farming module never starts)
2. Injects `play <bot> <appids>` into ASF's console via a FIFO right after startup (and immediately if ASF is already running)
3. Stores the mapping in `mode.conf` so it survives restarts

Switching back to card farming injects `resume <bot>` and removes `FarmingPausedByDefault`.

## Runtime details

- ASF generic packages do not bundle a runtime; this project installs the **ASP.NET Core Runtime** (the exact channel is read from `ArchiSteamFarm.runtimeconfig.json`, so it always matches the ASF version in use)
- The runtime lives in `$ASF_HOME/runtime` and can be removed from the TUI; the next ASF start downloads it again automatically

## Updating

- The TUI's "Update Project" entry compares the local `version.txt` with `version.txt` published on your GitHub release page
- Publish a new `version.txt` on the GitHub release, and users will be offered the update

## Project layout

```
$ASF_HOME/
|-- asf/            # ASF generic package (extracted)
|-- runtime/        # managed .NET runtime
|-- asf-manager.sh  # this TUI manager
|-- manager.conf    # mirror / repo / version settings
|-- mode.conf       # play-only mode mappings (bot=appids)
|-- asf.pid         # running ASF pid
|-- asf.log         # captured ASF output when started from the TUI
|-- asf-input       # FIFO used for console command injection
`-- version.txt     # local project version
```

## License / disclaimer

Unofficial tooling for ArchiSteamFarm. Use at your own risk; automated playtime may violate Steam's rules.
