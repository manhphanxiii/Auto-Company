# Auto Company Index

## Purpose

This file is for quickly locating the repo's directory structure, script responsibilities, and call relationships, to make maintenance and troubleshooting easier.

## Directory Structure (current)

### Implementation directories (the single script entry point)

- `scripts/windows/`: Windows control, keep-alive, and autostart script implementations
- `scripts/core/`: main loop and core control script implementations
- `scripts/wsl/`: WSL `systemd --user` daemon script implementations
- `scripts/macos/`: macOS `launchd` daemon script implementations

Note: the repo root no longer keeps a script wrapper layer — execution and maintenance go entirely through `scripts/`.

### Other key directories

- `docs/`: documentation
- `logs/`: run logs
- `memories/`: consensus files
- `projects/`: projects produced by the auto company

## Core Runtime Logic (Windows + WSL)

Call chain (default):

`scripts/windows/start-win.ps1` -> WSL `systemd --user auto-company.service` -> `scripts/core/auto-loop.sh`

Notes:
- The default engine is `ENGINE=claude`
- You can switch to Codex via `.auto-loop.env` or `start-win.ps1 -Engine codex`
- There's no automatic engine fallback — if the selected engine is missing, it fails directly

Stop chain:

`scripts/windows/stop-win.ps1` -> stop `auto-company.service` + stop the `awake guardian` + stop the `wsl anchor`

## Script Responsibility Table (entry point / daemon / autostart / diagnostics)

| Category | Script Path | Main Responsibility |
|---|---|---|
| Entry point | `scripts/windows/start-win.ps1` | Starts the WSL daemon, writes `.auto-loop.env` (supports `ENGINE/CLAUDE_PERMISSION_MODE/CODEX_SANDBOX_MODE`), starts sleep-prevention and WSL keepalive |
| Entry point | `scripts/windows/stop-win.ps1` | Stops the daemon and reclaims sleep-prevention and WSL keepalive |
| Entry point | `scripts/windows/status-win.ps1` | Summarizes status across all 5 layers: guardian/keepalive/autostart/daemon/loop |
| Diagnostics | `scripts/windows/monitor-win.ps1` | Real-time logs |
| Diagnostics | `scripts/windows/last-win.ps1` | Full output of the most recent cycle |
| Diagnostics | `scripts/windows/cycles-win.ps1` | Cycle summary |
| Diagnostics | `scripts/windows/dashboard-win.ps1` | Starts the local web visualization dashboard |
| Keep-alive | `scripts/windows/awake-guardian-win.ps1` | Prevents sleep during runtime (`start/stop/status/run`) |
| Keep-alive | `scripts/windows/wsl-anchor-win.ps1` | Keeps the WSL session resident (`start/stop/status/run`) |
| Autostart | `scripts/windows/enable-autostart-win.ps1` | Creates the logon autostart task |
| Autostart | `scripts/windows/disable-autostart-win.ps1` | Removes the logon autostart task |
| Autostart | `scripts/windows/autostart-status-win.ps1` | Queries the autostart task status |
| Daemon | `scripts/wsl/install-wsl-daemon.sh` | Installs and enables `auto-company.service` |
| Daemon | `scripts/wsl/uninstall-wsl-daemon.sh` | Uninstalls the WSL daemon |
| Daemon | `scripts/wsl/wsl-daemon-status.sh` | Queries the WSL daemon status |
| Daemon | `scripts/macos/install-daemon.sh` | Installs/uninstalls the macOS launchd daemon |
| Core | `scripts/core/auto-loop.sh` | Main loop execution, circuit breaker, logging, consensus updates |
| Core | `scripts/core/monitor.sh` | Core status/log output |
| Core | `scripts/core/stop-loop.sh` | Core stop/pause/resume control |

## Quick Troubleshooting Path

1. Start with `scripts/windows/status-win.ps1`
2. Then check `scripts/windows/dashboard-win.ps1` or `scripts/windows/monitor-win.ps1`
3. For daemon issues, check `scripts/wsl/wsl-daemon-status.sh`
4. For autostart issues, check `scripts/windows/autostart-status-win.ps1` (for permission issues, check an administrator PowerShell first)

## Maintenance Rules

1. New features should be implemented in the scripts under `scripts/` first.
2. Documentation changes must keep these in sync:
   - `README.md`
   - `README-ZH.md`
   - `docs/windows-setup.md`
   - this index file, `INDEX.md`
