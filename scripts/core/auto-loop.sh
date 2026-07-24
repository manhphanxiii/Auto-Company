#!/bin/bash
# ============================================================
# Auto Company — 24/7 Autonomous Loop
# ============================================================
# Keeps selected CLI engine (Claude/Codex) running continuously.
# Uses fresh sessions with consensus.md as the relay baton.
#
# Usage:
#   ./auto-loop.sh              # Run in foreground
#   ./auto-loop.sh --daemon     # Run via launchd (macOS only)
#
# Stop:
#   ./stop-loop.sh              # Graceful stop
#   kill $(cat .auto-loop.pid)  # Force stop
#
# Config (env vars):
#   ENGINE=claude               # Engine selection: claude|codex (default: claude)
#   MODEL=...                   # Optional model override (empty = engine default)
#   CLAUDE_BIN=...              # Optional Claude executable override
#   CLAUDE_PERMISSION_MODE=bypassPermissions
#                               # Claude permission mode (default: bypassPermissions)
#   CODEX_BIN=...               # Optional Codex executable override
#   CODEX_SANDBOX_MODE=danger-full-access
#                               # Codex sandbox mode (only for ENGINE=codex)
#   LOOP_INTERVAL=30            # Seconds between cycles (default: 30)
#   CYCLE_TIMEOUT_SECONDS=1800  # Max seconds per cycle before force-kill
#   MAX_CONSECUTIVE_ERRORS=5    # Circuit breaker threshold
#   COOLDOWN_SECONDS=300        # Cooldown after circuit break
#   LIMIT_WAIT_SECONDS=3600     # Wait on usage limit
#   MAX_LOGS=200                # Max cycle logs to keep
#   AUTO_LOOP_PROTECT_GITIGNORE=1
#                               # Restore .gitignore if a cycle mutates it
#   AUTO_LOOP_USE_CLAUDE_WATCH=0
#                               # Feature flag (default OFF): wrap ENGINE=claude cycles with the
#                               # claude-watch reliability supervisor (idle-timeout + max-duration)
#                               # instead of the hand-rolled max-duration-only watchdog. See
#                               # docs/devops/2026-07-24-claude-watch-dogfood-integration.md before
#                               # enabling — long sub-agent calls can go silent on stdout for the
#                               # full duration of their work, which is a real false-positive risk.
#   CLAUDE_WATCH_BIN=...        # Optional claude-watch executable override
#   CLAUDE_WATCH_IDLE_TIMEOUT=900
#                               # Seconds of stdout silence before claude-watch kills the cycle
#                               # (only used when AUTO_LOOP_USE_CLAUDE_WATCH=1)
#   CLAUDE_WATCH_MAX_DURATION=$CYCLE_TIMEOUT_SECONDS
#                               # Seconds; wall-clock ceiling passed to claude-watch (defaults to
#                               # the same value as CYCLE_TIMEOUT_SECONDS)
#   CLAUDE_WATCH_GRACE_PERIOD=10
#                               # Seconds between claude-watch's SIGTERM and SIGKILL
#   CLAUDE_WATCH_WEBHOOK=...    # Optional webhook URL for claude-watch failure alerts (empty = none)
#   CLAUDE_WATCH_AUTO_DISABLE_THRESHOLD=3
#                               # Automated kill-switch: after this many CONSECUTIVE cycles where
#                               # claude-watch was active AND the cycle failed in a way attributable
#                               # to claude-watch itself (idle-timeout/max-duration/exit 1/2, the
#                               # permission-denial/false-completion detectors/exit 3/4, or the
#                               # backstop watchdog), the loop flips the runtime CLAUDE_WATCH_ACTIVE
#                               # gate to 0 in-memory (no restart needed) and falls back to the legacy
#                               # watchdog for the rest of this run. Resets to 0 on any claude-watch-
#                               # active cycle that was NOT attributable to claude-watch. Exists
#                               # because no human watches these logs to do this manually. See
#                               # docs/devops/2026-07-24-claude-watch-dogfood-integration.md.
# ============================================================

set -euo pipefail

# Enable job control (monitor mode) even though this script is non-interactive.
# This is required (not optional) for the process-group-based kill below: with
# job control OFF (bash's default in a script), a backgrounded job stays in the
# SAME process group as this script itself, so there is no group to isolate
# and no safe way to signal "this job and everything it forked" without also
# risking the loop's own process. With job control ON, each `... &` launched
# directly in this script gets its own new process group whose pgid equals its
# own pid (verified empirically on this system; `setsid` is not installed here,
# so it is not a usable alternative — confirmed with `command -v setsid`).
set -m

# === Resolve project root (always relative to this script) ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

LOG_DIR="$PROJECT_DIR/logs"
CONSENSUS_FILE="$PROJECT_DIR/memories/consensus.md"
PROMPT_FILE="$PROJECT_DIR/PROMPT.md"
PID_FILE="$PROJECT_DIR/.auto-loop.pid"
STATE_FILE="$PROJECT_DIR/.auto-loop-state"

# Loop settings (all overridable via env vars)
ENGINE="${ENGINE:-claude}"
ENGINE="$(echo "$ENGINE" | tr '[:upper:]' '[:lower:]')"
MODEL="${MODEL:-}"
MODEL_LABEL="${MODEL:-config-default}"
CLAUDE_BIN="${CLAUDE_BIN:-}"
CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
CODEX_BIN="${CODEX_BIN:-}"
CODEX_SANDBOX_MODE="${CODEX_SANDBOX_MODE:-danger-full-access}"
LOOP_INTERVAL="${LOOP_INTERVAL:-30}"
CYCLE_TIMEOUT_SECONDS="${CYCLE_TIMEOUT_SECONDS:-1800}"
MAX_CONSECUTIVE_ERRORS="${MAX_CONSECUTIVE_ERRORS:-5}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-300}"
LIMIT_WAIT_SECONDS="${LIMIT_WAIT_SECONDS:-3600}"
MAX_LOGS="${MAX_LOGS:-200}"
AUTO_LOOP_PROTECT_GITIGNORE="${AUTO_LOOP_PROTECT_GITIGNORE:-1}"
AUTO_LOOP_USE_CLAUDE_WATCH="${AUTO_LOOP_USE_CLAUDE_WATCH:-0}"
CLAUDE_WATCH_BIN="${CLAUDE_WATCH_BIN:-}"
CLAUDE_WATCH_IDLE_TIMEOUT="${CLAUDE_WATCH_IDLE_TIMEOUT:-900}"
CLAUDE_WATCH_MAX_DURATION="${CLAUDE_WATCH_MAX_DURATION:-$CYCLE_TIMEOUT_SECONDS}"
CLAUDE_WATCH_GRACE_PERIOD="${CLAUDE_WATCH_GRACE_PERIOD:-10}"
CLAUDE_WATCH_WEBHOOK="${CLAUDE_WATCH_WEBHOOK:-}"
CLAUDE_WATCH_AUTO_DISABLE_THRESHOLD="${CLAUDE_WATCH_AUTO_DISABLE_THRESHOLD:-3}"
CLAUDE_WATCH_ROLLING_WINDOW_SIZE="${CLAUDE_WATCH_ROLLING_WINDOW_SIZE:-$((CLAUDE_WATCH_AUTO_DISABLE_THRESHOLD * 2))}"
CLAUDE_WATCH_ROLLING_WINDOW_THRESHOLD="${CLAUDE_WATCH_ROLLING_WINDOW_THRESHOLD:-$CLAUDE_WATCH_AUTO_DISABLE_THRESHOLD}"
RESOLVED_ENGINE_BIN=""
RESOLVED_CLAUDE_WATCH_BIN=""
CLAUDE_WATCH_ACTIVE=0
# Set by run_claude_cycle_watched on every watched cycle: 1 if the outcome is
# attributable to claude-watch itself (idle-timeout, max-duration, the
# permission-denial/false-completion detectors, or the backstop watchdog),
# 0 for a clean exit or a passthrough exit code from the wrapped claude
# process. Distinct from CYCLE_TIMED_OUT, which only covers the subset of
# these (1/2/backstop) where the soft-timeout-but-consensus-updated escape
# hatch is meaningful -- see the auto-disable kill-switch in the main loop.
CLAUDE_WATCH_ATTRIBUTABLE_FAILURE=0
CYCLE_TIMEOUT_LABEL="${CYCLE_TIMEOUT_SECONDS}s"

if [ "$ENGINE" != "claude" ] && [ "$ENGINE" != "codex" ]; then
    echo "Error: ENGINE must be 'claude' or 'codex' (received: '$ENGINE')."
    exit 1
fi

# Keep Agent Teams compatibility for legacy prompts/config.
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

# === Functions ===

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local msg="[$timestamp] $1"
    echo "$msg" >> "$LOG_DIR/auto-loop.log"
    if [ -t 1 ]; then
        echo "$msg"
    fi
}

log_cycle() {
    local cycle_num=$1
    local status=$2
    local msg=$3
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] Cycle #$cycle_num [$status] $msg" >> "$LOG_DIR/auto-loop.log"
    if [ -t 1 ]; then
        echo "[$timestamp] Cycle #$cycle_num [$status] $msg"
    fi
}

check_usage_limit() {
    local output="$1"
    if echo "$output" | grep -qi "usage limit\|rate limit\|too many requests\|resource_exhausted\|overloaded\|quota\|429\|billing\|insufficient credits"; then
        return 0
    fi
    return 1
}

check_stop_requested() {
    if [ -f "$PROJECT_DIR/.auto-loop-stop" ]; then
        rm -f "$PROJECT_DIR/.auto-loop-stop"
        return 0
    fi
    return 1
}

save_state() {
    cat > "$STATE_FILE" << EOF
LOOP_COUNT=$loop_count
ERROR_COUNT=$error_count
LAST_RUN=$(date '+%Y-%m-%d %H:%M:%S')
STATUS=$1
MODEL=$MODEL_LABEL
ENGINE=$ENGINE
EOF
}

cleanup() {
    log "=== Auto Loop Shutting Down (PID $$) ==="
    rm -f "$PID_FILE"
    save_state "stopped"
    exit 0
}

snapshot_gitignore() {
    if [ "$AUTO_LOOP_PROTECT_GITIGNORE" = "0" ]; then
        echo ""
        return
    fi

    local gitignore_file="$PROJECT_DIR/.gitignore"
    local snapshot_file=""
    if [ -f "$gitignore_file" ]; then
        snapshot_file=$(mktemp)
        cp "$gitignore_file" "$snapshot_file"
    fi
    echo "$snapshot_file"
}

restore_gitignore_if_changed() {
    local snapshot_file="$1"
    if [ "$AUTO_LOOP_PROTECT_GITIGNORE" = "0" ]; then
        [ -n "$snapshot_file" ] && rm -f "$snapshot_file"
        return
    fi

    local gitignore_file="$PROJECT_DIR/.gitignore"
    local changed=0

    if [ -f "$gitignore_file" ]; then
        if [ -z "$snapshot_file" ] || [ ! -f "$snapshot_file" ]; then
            changed=1
        elif ! cmp -s "$gitignore_file" "$snapshot_file"; then
            changed=1
        fi
    else
        if [ -n "$snapshot_file" ] && [ -f "$snapshot_file" ]; then
            changed=1
        fi
    fi

    if [ "$changed" -eq 1 ]; then
        if [ -n "$snapshot_file" ] && [ -f "$snapshot_file" ]; then
            cp "$snapshot_file" "$gitignore_file"
            log_cycle "$loop_count" "GUARD" "Blocked cycle mutation of .gitignore and restored baseline"
        else
            rm -f "$gitignore_file"
            log_cycle "$loop_count" "GUARD" "Blocked cycle-created .gitignore and removed it"
        fi
    fi

    [ -n "$snapshot_file" ] && rm -f "$snapshot_file"
}

get_file_size_bytes() {
    local target_file="$1"
    if [ ! -f "$target_file" ]; then
        echo 0
        return
    fi

    if stat -c%s "$target_file" >/dev/null 2>&1; then
        stat -c%s "$target_file"
        return
    fi

    if stat -f%z "$target_file" >/dev/null 2>&1; then
        stat -f%z "$target_file"
        return
    fi

    wc -c < "$target_file" | tr -d ' '
}

rotate_logs() {
    # Keep only the latest N cycle logs
    local count
    count=$(find "$LOG_DIR" -name "cycle-*.log" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt "$MAX_LOGS" ]; then
        local to_delete=$((count - MAX_LOGS))
        find "$LOG_DIR" -name "cycle-*.log" -type f | sort | head -n "$to_delete" | xargs rm -f 2>/dev/null || true
        log "Log rotation: removed $to_delete old cycle logs"
    fi

    # Rotate main log if over 10MB
    local log_size
    log_size=$(get_file_size_bytes "$LOG_DIR/auto-loop.log")
    if [ "$log_size" -gt 10485760 ]; then
        mv "$LOG_DIR/auto-loop.log" "$LOG_DIR/auto-loop.log.old"
        log "Main log rotated (was ${log_size} bytes)"
    fi
}

cleanup_accidental_root_artifacts() {
    local removed=0
    local removed_names=""
    local f base

    # Known accidental artifacts caused by malformed shell redirections in generated commands.
    for f in "$PROJECT_DIR"/=* "$PROJECT_DIR"/口径说明*; do
        [ -f "$f" ] || continue
        if [ ! -s "$f" ]; then
            rm -f "$f"
            removed=$((removed + 1))
            base=$(basename "$f")
            if [ -z "$removed_names" ]; then
                removed_names="$base"
            else
                removed_names="$removed_names, $base"
            fi
        fi
    done

    if [ "$removed" -gt 0 ]; then
        log_cycle "$loop_count" "GUARD" "Removed accidental root zero-byte artifact(s): $removed_names"
    fi
}

backup_consensus() {
    if [ -f "$CONSENSUS_FILE" ]; then
        cp "$CONSENSUS_FILE" "$CONSENSUS_FILE.bak"
    fi
}

restore_consensus() {
    if [ -f "$CONSENSUS_FILE.bak" ]; then
        cp "$CONSENSUS_FILE.bak" "$CONSENSUS_FILE"
        log "Consensus restored from backup after failed cycle"
    fi
}

validate_consensus() {
    if [ ! -s "$CONSENSUS_FILE" ]; then
        return 1
    fi
    if ! grep -q "^# Auto Company Consensus" "$CONSENSUS_FILE"; then
        return 1
    fi
    if ! grep -q "^## Next Action" "$CONSENSUS_FILE"; then
        return 1
    fi
    if ! grep -q "^## Company State" "$CONSENSUS_FILE"; then
        return 1
    fi
    return 0
}

consensus_changed_since_backup() {
    if [ ! -f "$CONSENSUS_FILE" ]; then
        return 1
    fi

    if [ ! -f "$CONSENSUS_FILE.bak" ]; then
        return 0
    fi

    if cmp -s "$CONSENSUS_FILE" "$CONSENSUS_FILE.bak"; then
        return 1
    fi

    return 0
}

resolve_codex_bin() {
    if [ -n "$CODEX_BIN" ]; then
        if [ -x "$CODEX_BIN" ]; then
            echo "$CODEX_BIN"
            return 0
        fi
        if command -v "$CODEX_BIN" >/dev/null 2>&1; then
            command -v "$CODEX_BIN"
            return 0
        fi
    fi

    # Prefer WSL-local Codex installed via nvm.
    local nvm_candidate=""
    for candidate in "$HOME"/.nvm/versions/node/*/bin/codex; do
        if [ -x "$candidate" ]; then
            nvm_candidate="$candidate"
        fi
    done
    if [ -n "$nvm_candidate" ]; then
        echo "$nvm_candidate"
        return 0
    fi

    # Fallback: ask an interactive bash shell (loads user profile).
    local interactive_candidate
    interactive_candidate=$(bash -ic 'command -v codex' 2>/dev/null | tail -n1 | tr -d '\r' || true)
    if [ -n "$interactive_candidate" ] && [ -x "$interactive_candidate" ]; then
        echo "$interactive_candidate"
        return 0
    fi

    # Last fallback: current shell PATH.
    if command -v codex >/dev/null 2>&1; then
        command -v codex
        return 0
    fi

    return 1
}

resolve_claude_bin() {
    if [ -n "$CLAUDE_BIN" ]; then
        if [ -x "$CLAUDE_BIN" ]; then
            echo "$CLAUDE_BIN"
            return 0
        fi
        if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
            command -v "$CLAUDE_BIN"
            return 0
        fi
    fi

    # Prefer WSL-local Claude CLI installed via nvm.
    local nvm_candidate=""
    for candidate in "$HOME"/.nvm/versions/node/*/bin/claude; do
        if [ -x "$candidate" ]; then
            nvm_candidate="$candidate"
        fi
    done
    if [ -n "$nvm_candidate" ]; then
        echo "$nvm_candidate"
        return 0
    fi

    # Fallback: ask an interactive bash shell (loads user profile).
    local interactive_candidate
    interactive_candidate=$(bash -ic 'command -v claude' 2>/dev/null | tail -n1 | tr -d '\r' || true)
    if [ -n "$interactive_candidate" ] && [ -x "$interactive_candidate" ]; then
        echo "$interactive_candidate"
        return 0
    fi

    # Last fallback: current shell PATH.
    if command -v claude >/dev/null 2>&1; then
        command -v claude
        return 0
    fi

    return 1
}

resolve_engine_bin() {
    case "$ENGINE" in
        claude)
            resolve_claude_bin
            ;;
        codex)
            resolve_codex_bin
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_claude_watch_bin() {
    if [ -n "$CLAUDE_WATCH_BIN" ]; then
        if [ -x "$CLAUDE_WATCH_BIN" ]; then
            echo "$CLAUDE_WATCH_BIN"
            return 0
        fi
        if command -v "$CLAUDE_WATCH_BIN" >/dev/null 2>&1; then
            command -v "$CLAUDE_WATCH_BIN"
            return 0
        fi
    fi

    if command -v claude-watch >/dev/null 2>&1; then
        command -v claude-watch
        return 0
    fi

    return 1
}

# Sends SIGTERM (then SIGKILL after a short grace period) to an entire process
# group, not just one tracked PID. Closes the orphaned-descendant gap: if the
# tracked process (legacy `claude`/`codex`, or `claude-watch run -- claude`)
# had already forked a child by the time it was killed/exited (e.g. a shell
# command from a tool call), that child is invisible to a plain `kill <pid>`
# and would otherwise keep running indefinitely under the same permission
# mode. Relies on the caller having launched the tracked process as its own
# process group (see `set -m` above), so pgid == the tracked pid.
#
# Always call this AFTER `wait`ing on the tracked pid, regardless of why it
# exited (clean success, legacy watchdog timeout, claude-watch's own
# idle-timeout/max-duration kill, or any other exit) — it is a final sweep,
# not a substitute for the existing timeout logic. Safe to call on an
# already-empty group: never errors, never hangs, never touches PID/PGID 0 or
# 1 (which would reach far more than the intended group).
# Re-verifies, immediately before a SIGKILL, that the surviving process group
# still looks like the invocation we launched -- guards against pgid reuse:
# on a long-running daemon, a pgid retired by the OS between our `wait` and
# this final check can be reassigned to a completely unrelated process by
# the time we get here. Matches on EITHER (a) any process in the group whose
# command line contains expected_pattern, or (b) the group leader (pid ==
# pgid) still being a direct child of this script ($$) -- see the Item 1
# design doc (docs/devops/2026-07-24-cycle28-hardening-design.md) for why
# both checks exist and why a non-matching orphaned descendant with an
# already-reparented ppid is an accepted, documented gap rather than a bug:
# ancestry back to $$ is unrecoverable at the OS level once a parent has
# died and the child has been reparented, so no check can close it. Fails
# safe on any ambiguity (ps missing/empty/unparseable, or no match at all):
# skip the KILL rather than signal an unverified target.
pgid_matches_expected() {
    local pgid="$1"
    local pattern="$2"
    local self_pid="$3"
    local rows

    rows=$(ps -eo pid=,ppid=,pgid=,command= 2>/dev/null | awk -v pg="$pgid" '$3 == pg')

    if [ -z "$rows" ]; then
        return 1
    fi
    if [ -z "$pattern" ]; then
        return 1
    fi

    if printf '%s\n' "$rows" | grep -F -q -- "$pattern"; then
        return 0
    fi

    if printf '%s\n' "$rows" | awk -v p="$pgid" -v s="$self_pid" \
        '$1 == p && $2 == s { f=1 } END { exit !f }'; then
        return 0
    fi

    return 1
}

terminate_process_group() {
    local pgid="$1"
    local expected_pattern="$2"

    if [ -z "$pgid" ] || [ "$pgid" -le 1 ] 2>/dev/null; then
        return 0
    fi

    if kill -0 -- "-$pgid" 2>/dev/null; then
        kill -TERM -- "-$pgid" 2>/dev/null || true
        sleep 5
        if kill -0 -- "-$pgid" 2>/dev/null; then
            if pgid_matches_expected "$pgid" "$expected_pattern" "$$"; then
                kill -KILL -- "-$pgid" 2>/dev/null || true
            else
                log "terminate_process_group: pgid $pgid survived SIGTERM but no longer verifiably matches expected invocation (pattern '$expected_pattern'); possible pgid reuse -- skipping SIGKILL to avoid signaling an unrelated process."
            fi
        fi
    fi
}

run_codex_cycle() {
    local prompt="$1"
    local output_file timeout_flag message_file

    output_file=$(mktemp)
    timeout_flag=$(mktemp)
    message_file=$(mktemp)

    set +e
    (
        cd "$PROJECT_DIR" || exit 1
        local codex_cmd=("$RESOLVED_ENGINE_BIN" "exec" "-c" "sandbox_mode=\"${CODEX_SANDBOX_MODE}\"" "-o" "$message_file")
        if [ -n "$MODEL" ]; then
            codex_cmd+=("-m" "$MODEL")
        fi
        codex_cmd+=("$prompt")
        "${codex_cmd[@]}"
    ) > "$output_file" 2>&1 &
    local codex_pid=$!
    # `set -m` (enabled at script startup) gives this backgrounded subshell
    # its own process group, with pgid == its own pid. Tracked so the
    # unconditional cleanup below can reach any orphaned descendant a plain
    # `kill $codex_pid` would miss.
    local codex_pgid="$codex_pid"

    (
        sleep "$CYCLE_TIMEOUT_SECONDS"
        if kill -0 "$codex_pid" 2>/dev/null; then
            echo "1" > "$timeout_flag"
            kill -TERM "$codex_pid" 2>/dev/null || true
            sleep 5
            kill -KILL "$codex_pid" 2>/dev/null || true
        fi
    ) &
    local watchdog_pid=$!

    wait "$codex_pid" 2>/dev/null
    EXIT_CODE=$?

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    set -e

    # Unconditional cleanup regardless of why codex_pid exited (clean success,
    # watchdog timeout, or any other exit) — sweep the whole process group
    # before reading the output files so no orphaned descendant is left
    # running, or still writing to output_file, invisibly.
    terminate_process_group "$codex_pgid" "codex"

    OUTPUT=$(cat "$output_file")
    RESULT_MESSAGE=$(cat "$message_file" 2>/dev/null || true)
    rm -f "$output_file" "$message_file"

    if [ -s "$timeout_flag" ]; then
        CYCLE_TIMED_OUT=1
        EXIT_CODE=124
    else
        CYCLE_TIMED_OUT=0
    fi
    rm -f "$timeout_flag"
}

run_claude_cycle() {
    local prompt="$1"
    if [ "$CLAUDE_WATCH_ACTIVE" -eq 1 ]; then
        run_claude_cycle_watched "$prompt"
    else
        run_claude_cycle_legacy "$prompt"
    fi
}

# Default path (AUTO_LOOP_USE_CLAUDE_WATCH=0, or claude-watch unresolvable).
# The success/timeout-detection logic itself is byte-for-byte the same
# behavior as before this integration was added; the only addition is the
# unconditional process-group cleanup sweep after `wait` returns (see
# terminate_process_group above), which does not change EXIT_CODE,
# CYCLE_TIMED_OUT, OUTPUT, or timing for the success/normal-timeout case.
run_claude_cycle_legacy() {
    local prompt="$1"
    local output_file timeout_flag

    output_file=$(mktemp)
    timeout_flag=$(mktemp)

    CYCLE_OUTPUT_FORMAT="json"
    CYCLE_TIMEOUT_LABEL="${CYCLE_TIMEOUT_SECONDS}s"

    set +e
    (
        cd "$PROJECT_DIR" || exit 1
        local claude_cmd=("$RESOLVED_ENGINE_BIN" "-p" "$prompt" "--output-format" "json")
        if [ -n "$MODEL" ]; then
            claude_cmd+=("--model" "$MODEL")
        fi
        if [ -n "$CLAUDE_PERMISSION_MODE" ]; then
            claude_cmd+=("--permission-mode" "$CLAUDE_PERMISSION_MODE")
        fi
        "${claude_cmd[@]}"
    ) > "$output_file" 2>&1 &
    local claude_pid=$!
    # `set -m` (enabled at script startup) gives this backgrounded subshell
    # its own process group, with pgid == its own pid. Tracked so the
    # unconditional cleanup below can reach any orphaned descendant a plain
    # `kill $claude_pid` would miss.
    local claude_pgid="$claude_pid"

    (
        sleep "$CYCLE_TIMEOUT_SECONDS"
        if kill -0 "$claude_pid" 2>/dev/null; then
            echo "1" > "$timeout_flag"
            kill -TERM "$claude_pid" 2>/dev/null || true
            sleep 5
            kill -KILL "$claude_pid" 2>/dev/null || true
        fi
    ) &
    local watchdog_pid=$!

    wait "$claude_pid" 2>/dev/null
    EXIT_CODE=$?

    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    set -e

    # Unconditional cleanup regardless of why claude_pid exited (clean
    # success, legacy watchdog timeout, or any other exit) — sweep the whole
    # process group before reading the output file so no orphaned descendant
    # is left running, or still writing to output_file, invisibly. This is
    # prerequisite #1 from the blocking-prerequisites review: closes the
    # orphaned-descendant gap that a plain `kill $claude_pid` leaves open.
    terminate_process_group "$claude_pgid" "claude"

    OUTPUT=$(cat "$output_file")
    RESULT_MESSAGE="$OUTPUT"
    rm -f "$output_file"

    if [ -s "$timeout_flag" ]; then
        CYCLE_TIMED_OUT=1
        EXIT_CODE=124
    else
        CYCLE_TIMED_OUT=0
    fi
    rm -f "$timeout_flag"
}

# Opt-in path (AUTO_LOOP_USE_CLAUDE_WATCH=1 and claude-watch resolvable).
# Wraps the claude invocation with claude-watch for real idle-timeout detection
# instead of the max-duration-only watchdog above. Requires --output-format
# stream-json (verified empirically: --verbose is required alongside it, and
# the NDJSON stream goes silent for the full duration of any sub-agent tool
# call rather than emitting incremental events — see the devops doc).
run_claude_cycle_watched() {
    local prompt="$1"
    local output_file backstop_flag

    output_file=$(mktemp)
    backstop_flag=$(mktemp)
    CYCLE_OUTPUT_FORMAT="stream-json"

    set +e
    (
        cd "$PROJECT_DIR" || exit 1
        local claude_cmd=("$RESOLVED_ENGINE_BIN" "-p" "$prompt" "--output-format" "stream-json" "--verbose")
        if [ -n "$MODEL" ]; then
            claude_cmd+=("--model" "$MODEL")
        fi
        if [ -n "$CLAUDE_PERMISSION_MODE" ]; then
            claude_cmd+=("--permission-mode" "$CLAUDE_PERMISSION_MODE")
        fi

        local watch_cmd=("$RESOLVED_CLAUDE_WATCH_BIN" "run" \
            "--idle-timeout" "${CLAUDE_WATCH_IDLE_TIMEOUT}s" \
            "--max-duration" "${CLAUDE_WATCH_MAX_DURATION}s" \
            "--grace-period" "${CLAUDE_WATCH_GRACE_PERIOD}s" \
            "--transcript-format" "stream-json")
        if [ -n "$CLAUDE_WATCH_WEBHOOK" ]; then
            watch_cmd+=("--webhook" "$CLAUDE_WATCH_WEBHOOK")
        fi
        watch_cmd+=("--")
        watch_cmd+=("${claude_cmd[@]}")

        "${watch_cmd[@]}"
    ) > "$output_file" 2>&1 &
    local watch_pid=$!
    # `set -m` (enabled at script startup) gives this backgrounded subshell
    # its own process group, with pgid == its own pid. Tracked so the
    # unconditional cleanup below can reach any orphaned descendant even
    # though claude-watch's own kill sequence only signals the direct
    # `claude` child it spawned, not that child's further descendants.
    local watch_pgid="$watch_pid"

    # Backstop watchdog: empirically, `wait "$watch_pid"` is NOT guaranteed to
    # return promptly on its own even after claude-watch correctly detects and
    # kills its direct child. claude-watch (Node) gates its own process exit
    # on the wrapped child's stdout/stderr stream fully closing; an orphaned
    # descendant that inherited a duplicate of that same pipe (exactly the
    # gap this function's cleanup exists to close) keeps the pipe open and
    # can therefore delay claude-watch's own exit — and thus this `wait` — for
    # as long as that descendant survives. This is the "delayed-return" risk
    # from finding #4 in the devops doc, confirmed empirically while building
    # this fix: without this backstop, a hung orphan can make the watched
    # path take as long as the orphan lives to return control to the loop,
    # regardless of how tight CLAUDE_WATCH_IDLE_TIMEOUT is set. Bounded to
    # whichever ceiling is larger — the same overall ceiling the legacy path
    # already guarantees (CYCLE_TIMEOUT_SECONDS), or claude-watch's own
    # configured max-duration if that was set higher than the cycle timeout —
    # plus room for claude-watch's own grace period to finish a clean kill
    # first.
    local watch_backstop_timeout
    if [ "$CLAUDE_WATCH_MAX_DURATION" -gt "$CYCLE_TIMEOUT_SECONDS" ]; then
        watch_backstop_timeout=$((CLAUDE_WATCH_MAX_DURATION + CLAUDE_WATCH_GRACE_PERIOD + 5))
    else
        watch_backstop_timeout=$((CYCLE_TIMEOUT_SECONDS + CLAUDE_WATCH_GRACE_PERIOD + 5))
    fi
    (
        sleep "$watch_backstop_timeout"
        if kill -0 -- "-$watch_pgid" 2>/dev/null; then
            echo "1" > "$backstop_flag"
            kill -TERM -- "-$watch_pgid" 2>/dev/null || true
            sleep 5
            kill -KILL -- "-$watch_pgid" 2>/dev/null || true
        fi
    ) &
    local watch_backstop_pid=$!

    wait "$watch_pid" 2>/dev/null
    EXIT_CODE=$?

    kill "$watch_backstop_pid" 2>/dev/null || true
    wait "$watch_backstop_pid" 2>/dev/null || true
    set -e

    # Unconditional cleanup regardless of why the wrapped process returned
    # (clean exit, claude-watch's own idle-timeout/max-duration kill, one of
    # its permission-denial/false-completion detectors, the backstop watchdog
    # above, or anything else) — sweep the whole process group before reading
    # the output file so no orphaned descendant is left running, or still
    # holding output_file's fd open. This is prerequisite #1 from the
    # blocking-prerequisites review, applied to the watched path.
    terminate_process_group "$watch_pgid" "claude"

    OUTPUT=$(cat "$output_file")
    RESULT_MESSAGE="$OUTPUT"
    rm -f "$output_file"

    if [ -s "$backstop_flag" ]; then
        # The backstop fired: claude-watch itself did not return within
        # watch_backstop_timeout, so we force-killed the whole group
        # (including claude-watch's own process) directly. This unavoidably
        # clobbers whatever exit code claude-watch would otherwise have
        # reported (EXIT_CODE here is just whatever a SIGTERM/SIGKILL of the
        # node process happens to produce, e.g. 143) — so this case is
        # classified as a timeout on EXIT_CODE alone, not the exit-code
        # case below, and must still count as claude-watch-attributable for
        # the auto-disable kill-switch (prerequisite #2): this scenario is
        # the clearest possible evidence claude-watch is not returning
        # control reliably.
        CYCLE_TIMED_OUT=1
        CLAUDE_WATCH_ATTRIBUTABLE_FAILURE=1
        CYCLE_TIMEOUT_LABEL="${watch_backstop_timeout}s claude-watch-backstop (claude-watch did not return control in time, likely an orphaned descendant per finding #4)"
    else
        # claude-watch exit codes: 0 clean, 1 idle-timeout, 2 max-duration,
        # 3/4 stream-json-only silent-failure detectors, otherwise the
        # wrapped claude process's own exit code passed through unchanged.
        #
        # 3/4 are NOT folded into CYCLE_TIMED_OUT: they are not timeouts (the
        # process already returned a definite exit code, nothing was killed
        # mid-flight), and the soft-timeout "consensus was still updated ->
        # treat as OK" escape hatch below would be actively wrong here -- a
        # false-completion detection specifically means the model claimed
        # done without actually finishing, so a consensus.md that merely
        # looks updated must not be allowed to launder that into an OK. They
        # already fall through to the generic `Exit code $EXIT_CODE` hard
        # failure path via the CYCLE_TIMED_OUT=0 case below, same as before.
        #
        # They DO count as CLAUDE_WATCH_ATTRIBUTABLE_FAILURE=1, unlike before
        # this fix: claude-watch positively detecting a bad terminal state is
        # at least as strong a signal for the auto-disable kill-switch as an
        # idle-timeout, arguably stronger. Previously this case fell into the
        # same `*)` branch as a genuine exit-0 success/passthrough code, which
        # reset the kill-switch counter to 0 instead of counting toward it --
        # found in independent critic-munger review of this diff, confirmed
        # against this exact code before being fixed.
        case "$EXIT_CODE" in
            1)
                CYCLE_TIMED_OUT=1
                CLAUDE_WATCH_ATTRIBUTABLE_FAILURE=1
                CYCLE_TIMEOUT_LABEL="${CLAUDE_WATCH_IDLE_TIMEOUT}s idle-timeout"
                ;;
            2)
                CYCLE_TIMED_OUT=1
                CLAUDE_WATCH_ATTRIBUTABLE_FAILURE=1
                CYCLE_TIMEOUT_LABEL="${CLAUDE_WATCH_MAX_DURATION}s max-duration"
                ;;
            3|4)
                CYCLE_TIMED_OUT=0
                CLAUDE_WATCH_ATTRIBUTABLE_FAILURE=1
                ;;
            *)
                CYCLE_TIMED_OUT=0
                CLAUDE_WATCH_ATTRIBUTABLE_FAILURE=0
                ;;
        esac
    fi
    rm -f "$backstop_flag"
}

run_engine_cycle() {
    local prompt="$1"
    case "$ENGINE" in
        claude)
            run_claude_cycle "$prompt"
            ;;
        codex)
            run_codex_cycle "$prompt"
            ;;
        *)
            echo "Error: Unsupported ENGINE '$ENGINE'" >&2
            return 1
            ;;
    esac
}

extract_cycle_metadata() {
    RESULT_TEXT=""
    CYCLE_COST="N/A"
    CYCLE_SUBTYPE="unknown"
    CYCLE_TYPE="${ENGINE}_exec"

    if [ "$ENGINE" = "claude" ]; then
        if [ "${CYCLE_OUTPUT_FORMAT:-json}" = "stream-json" ]; then
            # NDJSON transcript (claude-watch path): find the last line whose
            # .type == "result" and parse metadata from just that line. Non-JSON
            # lines (e.g. a stray CLI warning printed before the stream starts)
            # are skipped rather than aborting the whole parse.
            if command -v jq >/dev/null 2>&1; then
                result_line=$(echo "$RESULT_MESSAGE" | jq -R -c 'fromjson? | select(.type == "result")' 2>/dev/null | tail -n1 || true)
                if [ -n "$result_line" ]; then
                    RESULT_TEXT=$(echo "$result_line" | jq -r '.result // .message // .output_text // empty' 2>/dev/null | head -c 2000 || true)

                    parsed_cost=$(echo "$result_line" | jq -r '.total_cost_usd // .cost_usd // empty' 2>/dev/null || true)
                    if [ -n "$parsed_cost" ]; then
                        CYCLE_COST="$parsed_cost"
                    fi

                    parsed_subtype=$(echo "$result_line" | jq -r '.subtype // empty' 2>/dev/null || true)
                    if [ -n "$parsed_subtype" ]; then
                        CYCLE_SUBTYPE="$parsed_subtype"
                    fi

                    parsed_type=$(echo "$result_line" | jq -r '.type // empty' 2>/dev/null || true)
                    if [ -n "$parsed_type" ]; then
                        CYCLE_TYPE="$parsed_type"
                    fi
                fi
            fi

            if [ -z "$RESULT_TEXT" ]; then
                RESULT_TEXT=$(echo "$OUTPUT" | head -c 2000 || true)
            fi

            if [ "$CYCLE_SUBTYPE" = "unknown" ]; then
                if [ "$EXIT_CODE" -eq 0 ]; then
                    CYCLE_SUBTYPE="success"
                else
                    CYCLE_SUBTYPE="error"
                fi
            fi
            return
        fi

        if command -v jq >/dev/null 2>&1; then
            RESULT_TEXT=$(echo "$RESULT_MESSAGE" | jq -r '.result // .message // .output_text // empty' 2>/dev/null | head -c 2000 || true)
            if [ -z "$RESULT_TEXT" ]; then
                RESULT_TEXT=$(echo "$RESULT_MESSAGE" | jq -r '.. | .text? // empty' 2>/dev/null | head -c 2000 || true)
            fi

            parsed_cost=$(echo "$RESULT_MESSAGE" | jq -r '.total_cost_usd // .cost_usd // empty' 2>/dev/null || true)
            if [ -n "$parsed_cost" ]; then
                CYCLE_COST="$parsed_cost"
            fi

            parsed_subtype=$(echo "$RESULT_MESSAGE" | jq -r '.subtype // empty' 2>/dev/null || true)
            if [ -n "$parsed_subtype" ]; then
                CYCLE_SUBTYPE="$parsed_subtype"
            fi

            parsed_type=$(echo "$RESULT_MESSAGE" | jq -r '.type // empty' 2>/dev/null || true)
            if [ -n "$parsed_type" ]; then
                CYCLE_TYPE="$parsed_type"
            fi
        fi

        if [ -z "$RESULT_TEXT" ]; then
            RESULT_TEXT=$(echo "$OUTPUT" | head -c 2000 || true)
        fi

        if [ "$CYCLE_SUBTYPE" = "unknown" ]; then
            if [ "$EXIT_CODE" -eq 0 ]; then
                CYCLE_SUBTYPE="success"
            else
                CYCLE_SUBTYPE="error"
            fi
        fi
        return
    fi

    RESULT_TEXT=$(echo "$RESULT_MESSAGE" | head -c 2000 || true)
    if [ -z "$RESULT_TEXT" ]; then
        RESULT_TEXT=$(echo "$OUTPUT" | head -c 2000 || true)
    fi

    if [ "$EXIT_CODE" -eq 0 ]; then
        CYCLE_SUBTYPE="success"
    else
        CYCLE_SUBTYPE="error"
    fi
}

# === Setup ===

mkdir -p "$LOG_DIR" "$PROJECT_DIR/memories"

# Clean up stale stop file from previous run
rm -f "$PROJECT_DIR/.auto-loop-stop"

# Check for existing instance
if [ -f "$PID_FILE" ]; then
    existing_pid=$(cat "$PID_FILE")
    if kill -0 "$existing_pid" 2>/dev/null; then
        echo "Auto loop already running (PID $existing_pid). Stop it first with ./stop-loop.sh"
        exit 1
    fi
fi

# Check dependencies
if ! RESOLVED_ENGINE_BIN="$(resolve_engine_bin)"; then
    if [ "$ENGINE" = "claude" ]; then
        echo "Error: Claude CLI not found. Install Claude Code in WSL and verify with 'claude --version'."
    else
        echo "Error: Codex CLI not found. Install Codex in WSL and verify with 'codex --version'."
    fi
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: PROMPT.md not found at $PROMPT_FILE"
    exit 1
fi

# claude-watch is an optional dependency: never hard-fail the loop over it.
# Only relevant for ENGINE=claude; AUTO_LOOP_USE_CLAUDE_WATCH is ignored otherwise.
if [ "$AUTO_LOOP_USE_CLAUDE_WATCH" = "1" ] && [ "$ENGINE" = "claude" ]; then
    if RESOLVED_CLAUDE_WATCH_BIN="$(resolve_claude_watch_bin)"; then
        CLAUDE_WATCH_ACTIVE=1
    else
        log "AUTO_LOOP_USE_CLAUDE_WATCH=1 but claude-watch binary not found; falling back to legacy max-duration-only watchdog for this run."
    fi
fi

# Write PID file
echo $$ > "$PID_FILE"

# Trap signals for graceful shutdown
trap cleanup SIGTERM SIGINT SIGHUP

# Initialize counters
loop_count=0
error_count=0
claude_watch_consecutive_timeouts=0
claude_watch_rolling_history=()
claude_watch_rolling_failures=0

log "=== Auto Company Loop Started (PID $$) ==="
log "Project: $PROJECT_DIR"
if [ "$ENGINE" = "codex" ]; then
    log "Engine: codex | Model: $MODEL_LABEL | Sandbox: $CODEX_SANDBOX_MODE"
else
    log "Engine: claude | Model: $MODEL_LABEL | PermissionMode: $CLAUDE_PERMISSION_MODE"
fi
log "Engine bin: $RESOLVED_ENGINE_BIN"
engine_version=$("$RESOLVED_ENGINE_BIN" --version 2>/dev/null | head -n1 || true)
case "$RESOLVED_ENGINE_BIN" in
    /mnt/c/*)
        if [ "$ENGINE" = "codex" ]; then
            log "Warning: Codex binary resolves to Windows-mounted path. Prefer WSL-local install for stability."
        else
            log "Warning: Claude binary resolves to Windows-mounted path. Prefer WSL-local install for stability."
        fi
        ;;
esac
if [ -n "$engine_version" ]; then
    if [ "$ENGINE" = "codex" ]; then
        log "Codex version: $engine_version"
    else
        log "Claude version: $engine_version"
    fi
fi
log "Interval: ${LOOP_INTERVAL}s | Timeout: ${CYCLE_TIMEOUT_SECONDS}s | Breaker: ${MAX_CONSECUTIVE_ERRORS} errors"
if [ "$ENGINE" = "claude" ]; then
    if [ "$CLAUDE_WATCH_ACTIVE" -eq 1 ]; then
        log "claude-watch: ACTIVE ($RESOLVED_CLAUDE_WATCH_BIN) | idle-timeout: ${CLAUDE_WATCH_IDLE_TIMEOUT}s | max-duration: ${CLAUDE_WATCH_MAX_DURATION}s | grace-period: ${CLAUDE_WATCH_GRACE_PERIOD}s"
    else
        log "claude-watch: inactive (AUTO_LOOP_USE_CLAUDE_WATCH=$AUTO_LOOP_USE_CLAUDE_WATCH) | using legacy max-duration-only watchdog"
    fi
fi

# === Main Loop ===

while true; do
    # Check for stop request
    if check_stop_requested; then
        log "Stop requested. Shutting down gracefully."
        cleanup
    fi

    loop_count=$((loop_count + 1))
    cycle_log="$LOG_DIR/cycle-$(printf '%04d' "$loop_count")-$(date '+%Y%m%d-%H%M%S').log"

    log_cycle "$loop_count" "START" "Beginning work cycle"
    save_state "running"

    # Log rotation
    rotate_logs

    # Backup consensus before cycle
    backup_consensus
    gitignore_snapshot=$(snapshot_gitignore)

    # Build prompt with consensus pre-injected
    PROMPT=$(cat "$PROMPT_FILE")
    CONSENSUS=$(cat "$CONSENSUS_FILE" 2>/dev/null || echo "No consensus file found. This is the very first cycle.")
    FULL_PROMPT="$PROMPT

---

## Runtime Guardrails (must follow)

1. Early in the cycle, create or update \`memories/consensus.md\` with the required section skeleton.
2. If work scope is large, persist partial decisions to \`memories/consensus.md\` before deep dives.
3. Prefer shipping one completed milestone over broad parallel exploration.
4. Never write files via shell heredoc (\`cat <<EOF\`). Use \`apply_patch\` for file creates/edits.
5. Never execute shell lines that begin with \`>\` or \`>=\`; treat them as text and keep them inside markdown/files.

---

## Current Consensus (pre-loaded, do NOT re-read this file)

$CONSENSUS

---

This is Cycle #$loop_count. Act decisively."

    # Run selected engine in headless mode with per-cycle timeout
    cycle_used_claude_watch=$CLAUDE_WATCH_ACTIVE
    run_engine_cycle "$FULL_PROMPT"

    # Automated kill-switch (prerequisite #2 from the blocking-prerequisites
    # review): track CONSECUTIVE cycles where claude-watch was the active path
    # AND the cycle failed in a way attributable to claude-watch itself
    # (idle-timeout, max-duration, the permission-denial/false-completion
    # detectors, or the backstop watchdog -- see CLAUDE_WATCH_ATTRIBUTABLE_FAILURE
    # in run_claude_cycle_watched). Deliberately NOT keyed on CYCLE_TIMED_OUT:
    # that flag also gates the soft-timeout "consensus still updated -> OK"
    # escape hatch, which only makes sense for the timeout-like subset
    # (idle-timeout/max-duration/backstop) -- folding the detector cases into
    # it would wrongly grant them that escape hatch too. Reset on any
    # claude-watch-active cycle that was NOT attributable to claude-watch. No
    # human reads these logs to do this manually, so the disable must be
    # automatic, in-memory, and same-process — same pattern as error_count
    # below.
    if [ "$cycle_used_claude_watch" -eq 1 ]; then
        # --- Rolling window (belt-and-suspenders addition, cycle 28): tracks
        # the last CLAUDE_WATCH_ROLLING_WINDOW_SIZE claude-watch-active cycles
        # as a 0/1 ring buffer and counts failures in-window, independent of
        # whether they were consecutive. Catches flapping patterns
        # (fail/succeed/fail/succeed/...) that never accumulate N-in-a-row
        # and would otherwise never trip the consecutive check below. See
        # docs/devops/2026-07-24-cycle28-hardening-design.md for default
        # justification (M/N derived from CLAUDE_WATCH_AUTO_DISABLE_THRESHOLD).
        claude_watch_rolling_history+=("$CLAUDE_WATCH_ATTRIBUTABLE_FAILURE")
        claude_watch_rolling_failures=$((claude_watch_rolling_failures + CLAUDE_WATCH_ATTRIBUTABLE_FAILURE))
        if [ "${#claude_watch_rolling_history[@]}" -gt "$CLAUDE_WATCH_ROLLING_WINDOW_SIZE" ]; then
            evicted_bit="${claude_watch_rolling_history[0]}"
            claude_watch_rolling_history=("${claude_watch_rolling_history[@]:1}")
            claude_watch_rolling_failures=$((claude_watch_rolling_failures - evicted_bit))
        fi

        # --- Strictly-consecutive check (unchanged from cycle 27) ---
        if [ "$CLAUDE_WATCH_ATTRIBUTABLE_FAILURE" -eq 1 ]; then
            claude_watch_consecutive_timeouts=$((claude_watch_consecutive_timeouts + 1))
        else
            claude_watch_consecutive_timeouts=0
        fi

        # --- Trip: either mechanism can independently auto-disable ---
        if [ "$CLAUDE_WATCH_ACTIVE" -eq 1 ] && [ "$claude_watch_consecutive_timeouts" -ge "$CLAUDE_WATCH_AUTO_DISABLE_THRESHOLD" ]; then
            CLAUDE_WATCH_ACTIVE=0
            log_cycle "$loop_count" "GUARD" "Auto-disabled claude-watch after $claude_watch_consecutive_timeouts consecutive claude-watch-attributable failures (idle-timeout/max-duration/permission-denial/false-completion/backstop); falling back to legacy watchdog for the remainder of this run. (AUTO_LOOP_USE_CLAUDE_WATCH left unchanged for logging; only the runtime CLAUDE_WATCH_ACTIVE gate was flipped.)"
        elif [ "$CLAUDE_WATCH_ACTIVE" -eq 1 ] && [ "$claude_watch_rolling_failures" -ge "$CLAUDE_WATCH_ROLLING_WINDOW_THRESHOLD" ]; then
            CLAUDE_WATCH_ACTIVE=0
            log_cycle "$loop_count" "GUARD" "Auto-disabled claude-watch after $claude_watch_rolling_failures claude-watch-attributable failures in the last ${#claude_watch_rolling_history[@]} claude-watch-active cycles (rolling-window threshold ${CLAUDE_WATCH_ROLLING_WINDOW_THRESHOLD}/${CLAUDE_WATCH_ROLLING_WINDOW_SIZE}, non-consecutive flapping pattern); falling back to legacy watchdog for the remainder of this run. (AUTO_LOOP_USE_CLAUDE_WATCH left unchanged for logging; only the runtime CLAUDE_WATCH_ACTIVE gate was flipped.)"
        fi
    fi

    # Save full output to cycle log
    echo "$OUTPUT" > "$cycle_log"

    # Clean up known malformed-redirection artifacts created by bad generated shell commands.
    cleanup_accidental_root_artifacts
    restore_gitignore_if_changed "$gitignore_snapshot"

    # Extract result fields for status classification
    extract_cycle_metadata

    cycle_failed_reason=""
    cycle_soft_timeout=0
    if [ "$CYCLE_TIMED_OUT" -eq 1 ]; then
        if validate_consensus && consensus_changed_since_backup; then
            cycle_soft_timeout=1
        else
            cycle_failed_reason="Timed out after ${CYCLE_TIMEOUT_LABEL}"
        fi
    elif [ "$EXIT_CODE" -ne 0 ]; then
        cycle_failed_reason="Exit code $EXIT_CODE"
    elif ! validate_consensus; then
        cycle_failed_reason="consensus.md validation failed after cycle"
    elif ! consensus_changed_since_backup; then
        cycle_failed_reason="consensus.md was not updated this cycle (mandatory baton update missing)"
    fi

    if [ "$cycle_soft_timeout" -eq 1 ]; then
        log_cycle "$loop_count" "OK" "Timed out after ${CYCLE_TIMEOUT_LABEL} but consensus was updated; keeping progress (cost: ${CYCLE_COST}, subtype: ${CYCLE_SUBTYPE})"
        if [ -n "$RESULT_TEXT" ]; then
            log_cycle "$loop_count" "SUMMARY" "$(echo "$RESULT_TEXT" | head -c 300)"
        fi
        error_count=0
    elif [ -z "$cycle_failed_reason" ]; then
        log_cycle "$loop_count" "OK" "Completed (cost: ${CYCLE_COST}, subtype: ${CYCLE_SUBTYPE})"
        if [ -n "$RESULT_TEXT" ]; then
            log_cycle "$loop_count" "SUMMARY" "$(echo "$RESULT_TEXT" | head -c 300)"
        fi
        error_count=0
    else
        error_count=$((error_count + 1))
        log_cycle "$loop_count" "FAIL" "$cycle_failed_reason (cost: ${CYCLE_COST}, subtype: ${CYCLE_SUBTYPE}, errors: $error_count/$MAX_CONSECUTIVE_ERRORS)"

        # Restore consensus on hard failure
        restore_consensus

        # Check for usage limit
        if check_usage_limit "$OUTPUT"; then
            log_cycle "$loop_count" "LIMIT" "API usage limit detected. Waiting ${LIMIT_WAIT_SECONDS}s..."
            save_state "waiting_limit"
            sleep "$LIMIT_WAIT_SECONDS"
            error_count=0
            continue
        fi

        # Circuit breaker
        if [ "$error_count" -ge "$MAX_CONSECUTIVE_ERRORS" ]; then
            log_cycle "$loop_count" "BREAKER" "Circuit breaker tripped! Cooling down ${COOLDOWN_SECONDS}s..."
            save_state "circuit_break"
            sleep "$COOLDOWN_SECONDS"
            error_count=0
            log "Circuit breaker reset. Resuming..."
        fi
    fi

    save_state "idle"
    log_cycle "$loop_count" "WAIT" "Sleeping ${LOOP_INTERVAL}s before next cycle..."
    sleep "$LOOP_INTERVAL"
done
