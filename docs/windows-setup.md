# Windows + WSL Setup Guide

On Windows, this project uses:

- Windows PowerShell as the control entry point
- WSL2 (Ubuntu + systemd) as the execution kernel
- WSL `systemd --user` providing daemon supervision and crash auto-restart
- Windows `scripts/windows/awake-guardian-win.ps1` providing runtime sleep-prevention
- Windows `scripts/windows/wsl-anchor-win.ps1` providing WSL session keep-alive (preventing idle exit)

## 1. One-Time Install (inside WSL)

Run in an Ubuntu terminal:

```bash
sudo apt update
sudo apt install -y make jq curl

# Install Node.js (LTS recommended)
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt install -y nodejs

# Install Claude Code (the default engine)
npm install -g @anthropic-ai/claude-code

# Optional: install the Codex CLI (for ENGINE=codex)
npm install -g @openai/codex
```

## 2. One-Time Self-Check (inside WSL)

```bash
make --version
claude --version
codex --version
jq --version
systemctl --user --version
ps -p 1 -o comm=
```

Pass criteria:
- `systemctl --user --version` succeeds
- `ps -p 1 -o comm=` outputs `systemd`

Recommended additional check of the engine path (check at least the engine you plan to use):

```bash
bash -lc 'command -v claude; claude --version'
bash -lc 'command -v codex; codex --version'
bash -ic 'command -v claude; claude --version'
bash -ic 'command -v codex; codex --version'
```

It should preferably hit a local WSL path (`/home/<user>/...`), avoiding `/mnt/c/...`.

Recommended one-time enabling of linger (improves user service persistence):

```powershell
wsl -d Ubuntu -u root loginctl enable-linger <your-user>
```

## 3. Prerequisites (before every session)

1. `make`, `claude`, `jq`, and `systemctl --user` are available in WSL (if you need codex, also confirm `codex`).
2. The target engine is logged in and usable inside WSL (default `claude`).
3. Recommended: confirm the target engine's path is preferably a local WSL path (`/home/...`).

Optional quick check (PowerShell):

```powershell
wsl -d Ubuntu bash -lc 'make --version; claude --version; jq --version; systemctl --user --version'
wsl -d Ubuntu bash -lc 'command -v claude'
# Optional (for ENGINE=codex):
wsl -d Ubuntu bash -lc 'codex --version; command -v codex'
```

## 4. Recommended Operation (standard)

Run from the repo root:

```powershell
# Default: Claude
.\scripts\windows\start-win.ps1 -Engine claude -ClaudePermissionMode bypassPermissions -CycleTimeoutSeconds 1800 -LoopInterval 30

# Switch to Codex
.\scripts\windows\start-win.ps1 -Engine codex -SandboxMode workspace-write -CycleTimeoutSeconds 1800 -LoopInterval 30

.\scripts\windows\status-win.ps1
.\scripts\windows\monitor-win.ps1
.\scripts\windows\last-win.ps1
.\scripts\windows\cycles-win.ps1
.\scripts\windows\stop-win.ps1
.\scripts\windows\dashboard-win.ps1
```

Notes:
- `.\scripts\windows\start-win.ps1` writes `.auto-loop.env` and starts `auto-company.service` + the `awake guardian` + the `wsl anchor`
- `.\scripts\windows\stop-win.ps1` stops `auto-company.service` and shuts down the `awake guardian` + the `wsl anchor`
- `.\scripts\windows\dashboard-win.ps1` starts the local web dashboard (default `http://127.0.0.1:8787`)

Recommended parameters:
- `CycleTimeoutSeconds`: `900-1800`
- `LoopInterval`: `30-60`
- `Engine`: `claude` (default) or `codex`
- `SandboxMode`: only takes effect when `ENGINE=codex` (backward-compatible with the old `CodexSandboxMode` parameter)
- `ClaudePermissionMode`: defaults to `bypassPermissions`

Script location notes:
- All script implementations live under `scripts/windows/`, `scripts/core/`, `scripts/wsl/`, `scripts/macos/`
- Day-to-day execution also uses the scripts under `scripts/` uniformly
- If you need to change the maintenance logic, edit the corresponding implementation file under `scripts/` directly

## 5. Optional: Start on Logon

Disabled by default. Enable it when needed:

```powershell
.\scripts\windows\enable-autostart-win.ps1
.\scripts\windows\autostart-status-win.ps1
```

Disable it:

```powershell
.\scripts\windows\disable-autostart-win.ps1
```

Autostart task name: `AutoCompany-WSL-Start` (trigger: At logon).
If you see `Access is denied`, re-run it from an administrator PowerShell.

## 6. Chat-First Mode (conversing with Claude/Codex)

If you don't want to run commands manually, you can just chat with Claude/Codex in Windows and have it operate on your behalf.

Underlying call chain:

`scripts/windows/start-win.ps1` -> WSL `systemd --user` -> `scripts/core/auto-loop.sh`

The core behavior is identical to the manual commands — the only difference is the entry point.

## 7. Common Issues

### `bad interpreter: /bin/bash^M`

- Cause: the file is CRLF
- Fix:

```bash
git config core.autocrlf false
git config core.eol lf
```

### `claude`/`codex` command not found (or node not found)

- Cause: WSL is missing Node or the target engine's CLI
- Fix: go back to step 1 and reinstall

### Claude gets stuck on a permission confirmation at runtime

- Cause: `CLAUDE_PERMISSION_MODE` is set too strictly, blocking the non-interactive flow
- Fix: explicitly pass `-ClaudePermissionMode bypassPermissions` at startup
- Diagnose: check `logs/auto-loop.log` for `Engine: claude | ... | PermissionMode: ...`

### `systemctl --user` is unavailable

- Cause: WSL doesn't have systemd enabled, or the session wasn't initialized correctly
- Fix:
  - First confirm `ps -p 1 -o comm=` is `systemd`
  - Then verify `systemctl --user --version`
  - If necessary, restart the WSL session and try again

### The log shows the engine binary at `/mnt/c/...`

- Cause: PATH is hitting the Windows-side CLI first
- Impact: the version and behavior may not match the local WSL terminal
- Fix: install and prioritize the local CLI inside WSL (`/home/<user>/...`)

### The guardian fails to start

- Symptom: `scripts/windows/start-win.ps1` reports the daemon started, but the guardian failed to start and returned a non-zero exit code
- Fix: first run `.\scripts\windows\status-win.ps1` to confirm service status, then manually run `.\scripts\windows\awake-guardian-win.ps1 -Action start`

### Frequent `Cycle #1 START` accompanied by `Auto Loop Shutting Down`

- Cause: the WSL session was reclaimed (common when linger isn't enabled or keepalive is missing)
- Fix:
  - Confirm `wsl-anchor` is RUNNING: `.\scripts\windows\status-win.ps1`
  - Enable linger once: `wsl -d Ubuntu -u root loginctl enable-linger <your-user>`
  - Restart the service: `.\scripts\windows\stop-win.ps1` then `.\scripts\windows\start-win.ps1`

### The autostart script reports `Access is denied`

- Cause: the current PowerShell session doesn't have enough permission to write the scheduled task
- Fix: run from an administrator PowerShell:
  - `.\scripts\windows\enable-autostart-win.ps1`
  - `.\scripts\windows\disable-autostart-win.ps1`
