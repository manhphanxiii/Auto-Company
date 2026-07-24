#!/bin/bash
# Regression tests for the cycle-28/30 hardening mechanisms in
# scripts/core/auto-loop.sh:
#   - pgid_matches_expected()          (pgid-reuse guard before a final SIGKILL)
#   - rolling_window_record()          (claude-watch flapping kill-switch)
#   - claude_watch_trial_signoff_valid() (governance gate for the claude-watch
#     dogfood trial -- cycle #30)
#
# Dependency-free, bash 3.2 compatible (macOS default /bin/bash). Does NOT
# source auto-loop.sh directly -- that file runs `set -euo pipefail`/`set -m`
# at top level and ends in an unconditional `while true` main loop that would
# hang and try to invoke external engine binaries (claude/codex). Instead,
# this extracts ONLY the two function definitions under test out of the real
# shipped source via awk (matched by function-boundary pattern) and `eval`s
# them into this process. That means these tests exercise the actual shipped
# code, not a hand-copied reimplementation that could drift out of sync.
#
# Run: bash tests/test_auto_loop_hardening.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/scripts/core/auto-loop.sh"

pass_count=0
fail_count=0

ok() {
    pass_count=$((pass_count + 1))
    echo "ok - $1"
}

not_ok() {
    fail_count=$((fail_count + 1))
    echo "not ok - $1"
}

if [ ! -f "$TARGET" ]; then
    echo "Bail out! target file not found: $TARGET"
    exit 1
fi

# --- Extract the two functions under test from the real, shipped source ---

pgid_matches_expected_src=$(awk '/^pgid_matches_expected\(\) \{/,/^\}/' "$TARGET")
rolling_window_record_src=$(awk '/^rolling_window_record\(\) \{/,/^\}/' "$TARGET")
claude_watch_trial_signoff_valid_src=$(awk '/^claude_watch_trial_signoff_valid\(\) \{/,/^\}/' "$TARGET")

if [ -z "$pgid_matches_expected_src" ]; then
    echo "Bail out! could not extract pgid_matches_expected() from $TARGET"
    exit 1
fi
if [ -z "$rolling_window_record_src" ]; then
    echo "Bail out! could not extract rolling_window_record() from $TARGET"
    exit 1
fi
if [ -z "$claude_watch_trial_signoff_valid_src" ]; then
    echo "Bail out! could not extract claude_watch_trial_signoff_valid() from $TARGET"
    exit 1
fi

# Guard against the awk range silently over-capturing a second function (e.g.
# if a closing brace is ever reformatted off column 0, the range would keep
# consuming lines through the NEXT function's closing brace instead). Fail
# loudly rather than eval-ing and testing unintended code.
assert_single_function_extracted() {
    local name="$1"
    local src="$2"
    local def_count
    def_count=$(printf '%s\n' "$src" | grep -cE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{')
    if [ "$def_count" -ne 1 ]; then
        echo "Bail out! extraction for $name captured $def_count function definitions (expected exactly 1) -- awk range likely over-captured past its intended closing brace"
        exit 1
    fi
}
assert_single_function_extracted "pgid_matches_expected" "$pgid_matches_expected_src"
assert_single_function_extracted "rolling_window_record" "$rolling_window_record_src"
assert_single_function_extracted "claude_watch_trial_signoff_valid" "$claude_watch_trial_signoff_valid_src"

eval "$pgid_matches_expected_src"
eval "$rolling_window_record_src"
eval "$claude_watch_trial_signoff_valid_src"

if ! type pgid_matches_expected >/dev/null 2>&1; then
    echo "Bail out! eval of extracted pgid_matches_expected() did not define the function"
    exit 1
fi
if ! type rolling_window_record >/dev/null 2>&1; then
    echo "Bail out! eval of extracted rolling_window_record() did not define the function"
    exit 1
fi
if ! type claude_watch_trial_signoff_valid >/dev/null 2>&1; then
    echo "Bail out! eval of extracted claude_watch_trial_signoff_valid() did not define the function"
    exit 1
fi

# claude_watch_trial_signoff_valid() calls log(...) and references $PROJECT_DIR
# and $SCRIPT_DIR as globals (matching how it's actually called in the real
# script -- not parameters). Stub log() and point those globals at an isolated
# scratch git repo below so these tests never read or mutate the real repo's
# git index/working tree.
log() { :; }

# =====================================================================
# pgid_matches_expected(pgid, pattern, self_pid) tests
# =====================================================================
#
# pgid_matches_expected calls `ps -eo pid=,ppid=,pgid=,command=`. We shadow
# the `ps` builtin with a bash function of the same name defined fresh right
# before each test case (a function definition in the same shell shadows the
# external binary without touching PATH), and unset it after each case so
# fixtures never leak into one another.

TEST_PGID=100
TEST_SELF_PID=999
TEST_PATTERN="claude-watch"

# --- Case 1: leader-alive ---
ps() { printf '100 1 100 claude-watch run -- claude foo\n'; }
if pgid_matches_expected "$TEST_PGID" "$TEST_PATTERN" "$TEST_SELF_PID"; then
    ok "pgid_matches_expected: leader-alive (pid==pgid, command matches pattern) -> match"
else
    not_ok "pgid_matches_expected: leader-alive (pid==pgid, command matches pattern) -> match"
fi
unset -f ps

# --- Case 2: claude-watch-substring (non-leader descendant matches) ---
ps() {
    printf '100 1 100 bash\n'
    printf '101 100 100 claude-watch run -- claude foo\n'
}
if pgid_matches_expected "$TEST_PGID" "$TEST_PATTERN" "$TEST_SELF_PID"; then
    ok "pgid_matches_expected: claude-watch-substring (non-leader descendant matches pattern) -> match"
else
    not_ok "pgid_matches_expected: claude-watch-substring (non-leader descendant matches pattern) -> match"
fi
unset -f ps

# --- Case 3: pre-exec ppid==self (not yet exec'd, no pattern match yet) ---
ps() { printf '100 999 100 sh -c true\n'; }
if pgid_matches_expected "$TEST_PGID" "$TEST_PATTERN" "$TEST_SELF_PID"; then
    ok "pgid_matches_expected: pre-exec ppid==self (pid==pgid, ppid==self_pid, no pattern yet) -> match via ancestry"
else
    not_ok "pgid_matches_expected: pre-exec ppid==self (pid==pgid, ppid==self_pid, no pattern yet) -> match via ancestry"
fi
unset -f ps

# --- Case 4: matching-orphan (leader already gone entirely; only a reparented
# orphan remains in `ps` output, ppid != self_pid, pattern still matches).
# Distinct from case 2: case 2 has BOTH a non-matching leader row and a
# matching descendant row; here the leader is fully absent, so this exercises
# the substring-match path with a single, already-reparented row and no
# leader row present at all.
ps() { printf '101 1 100 claude-watch run -- claude foo\n'; }
if pgid_matches_expected "$TEST_PGID" "$TEST_PATTERN" "$TEST_SELF_PID"; then
    ok "pgid_matches_expected: matching-orphan (leader absent, only reparented orphan row, pattern matches) -> match"
else
    not_ok "pgid_matches_expected: matching-orphan (leader absent, only reparented orphan row, pattern matches) -> match"
fi
unset -f ps

# --- Case 5: ambiguous-orphan-must-skip (no pattern match, no ppid==self) ---
ps() {
    printf '100 1 100 bash\n'
    printf '101 100 100 sh\n'
}
if pgid_matches_expected "$TEST_PGID" "$TEST_PATTERN" "$TEST_SELF_PID"; then
    not_ok "pgid_matches_expected: ambiguous-orphan-must-skip (no pattern match, no ppid==self) -> no match"
else
    ok "pgid_matches_expected: ambiguous-orphan-must-skip (no pattern match, no ppid==self) -> no match"
fi
unset -f ps

# --- Case 6: unrelated-reuse-must-skip (completely different process tree) ---
ps() {
    printf '100 1 100 nginx: worker process\n'
    printf '102 100 100 nginx: worker process\n'
}
if pgid_matches_expected "$TEST_PGID" "$TEST_PATTERN" "$TEST_SELF_PID"; then
    not_ok "pgid_matches_expected: unrelated-reuse-must-skip (unrelated process tree at reused pgid) -> no match"
else
    ok "pgid_matches_expected: unrelated-reuse-must-skip (unrelated process tree at reused pgid) -> no match"
fi
unset -f ps

# --- Case 7: empty/failed ps ---
ps() { :; }
if pgid_matches_expected "$TEST_PGID" "$TEST_PATTERN" "$TEST_SELF_PID"; then
    not_ok "pgid_matches_expected: empty/failed ps (no output) -> no match"
else
    ok "pgid_matches_expected: empty/failed ps (no output) -> no match"
fi
unset -f ps

# --- Case 8: empty pattern (valid non-empty rows, but pattern arg is "") ---
ps() { printf '100 1 100 claude-watch run -- claude foo\n'; }
if pgid_matches_expected "$TEST_PGID" "" "$TEST_SELF_PID"; then
    not_ok "pgid_matches_expected: empty pattern argument -> no match (explicit early return)"
else
    ok "pgid_matches_expected: empty pattern argument -> no match (explicit early return)"
fi
unset -f ps

# =====================================================================
# rolling_window_record(bit, window_size) tests
# =====================================================================
# Each case resets the globals rolling_window_record mutates before running.

# --- Case 1: alternation-trips-within-window ---
claude_watch_rolling_history=()
claude_watch_rolling_failures=0
for bit in 0 1 0 1 0 1; do
    rolling_window_record "$bit" 6
done
if [ "$claude_watch_rolling_failures" -eq 3 ]; then
    ok "rolling_window_record: alternation-trips-within-window (0,1,0,1,0,1 / window=6) -> failures==3"
else
    not_ok "rolling_window_record: alternation-trips-within-window (0,1,0,1,0,1 / window=6) -> failures==3 (got $claude_watch_rolling_failures)"
fi

# --- Case 2: all-consecutive-no-regression ---
claude_watch_rolling_history=()
claude_watch_rolling_failures=0
for bit in 1 1 1 1 1 1; do
    rolling_window_record "$bit" 6
done
if [ "$claude_watch_rolling_failures" -eq 6 ] && [ "${#claude_watch_rolling_history[@]}" -eq 6 ]; then
    ok "rolling_window_record: all-consecutive-no-regression (six 1s / window=6) -> failures==6, history len==6"
else
    not_ok "rolling_window_record: all-consecutive-no-regression (six 1s / window=6) -> failures==6, history len==6 (got failures=$claude_watch_rolling_failures len=${#claude_watch_rolling_history[@]})"
fi

# --- Case 3: sparse-no-trip ---
claude_watch_rolling_history=()
claude_watch_rolling_failures=0
for bit in 1 0 0 0 0 0; do
    rolling_window_record "$bit" 6
done
if [ "$claude_watch_rolling_failures" -eq 1 ]; then
    ok "rolling_window_record: sparse-no-trip (1,0,0,0,0,0 / window=6) -> failures==1"
else
    not_ok "rolling_window_record: sparse-no-trip (1,0,0,0,0,0 / window=6) -> failures==1 (got $claude_watch_rolling_failures)"
fi

# --- Case 4: eviction-arithmetic-over-many-cycles ---
# Deterministic (non-random) bit sequence derived from a fixed arithmetic
# formula on the cycle index, fed through 55 sequential calls with
# window_size=6. After every single call we independently recompute the
# expected failures count (sum of the last min(N,6) fed bits, tracked in a
# plain bash array kept only by this test) and compare against the actual
# global mutated by the function under test.
claude_watch_rolling_history=()
claude_watch_rolling_failures=0
window=6
fed_bits=()
drift_found=0
drift_at=0
i=1
while [ "$i" -le 55 ]; do
    m=$(( (i * 3 + 1) % 5 ))
    if [ "$m" -lt 2 ]; then
        bit=1
    else
        bit=0
    fi
    fed_bits+=("$bit")
    rolling_window_record "$bit" "$window"

    len=${#fed_bits[@]}
    if [ "$len" -gt "$window" ]; then
        start=$((len - window))
    else
        start=0
    fi
    expected_sum=0
    j=$start
    while [ "$j" -lt "$len" ]; do
        expected_sum=$((expected_sum + fed_bits[j]))
        j=$((j + 1))
    done

    if [ "$claude_watch_rolling_failures" -ne "$expected_sum" ]; then
        drift_found=1
        drift_at=$i
        break
    fi
    i=$((i + 1))
done
if [ "$drift_found" -eq 0 ]; then
    ok "rolling_window_record: eviction-arithmetic-over-many-cycles (55 cycles, window=6) -> drift-free"
else
    not_ok "rolling_window_record: eviction-arithmetic-over-many-cycles (55 cycles, window=6) -> drift-free (mismatch at cycle $drift_at: got $claude_watch_rolling_failures, expected $expected_sum)"
fi

# --- Case 5: custom-window-override ---
claude_watch_rolling_history=()
claude_watch_rolling_failures=0
for bit in 1 1 0 1 1; do
    rolling_window_record "$bit" 4
done
# Fed: 1,1,0,1,1 (5 bits) with window_size=4 -> oldest (first) 1 is evicted,
# so history should hold the last 4 fed bits (1,0,1,1) and failures should
# reflect only those (3), not the sum of all 5 fed bits (4).
if [ "$claude_watch_rolling_failures" -eq 3 ] && [ "${#claude_watch_rolling_history[@]}" -eq 4 ] \
    && [ "${claude_watch_rolling_history[0]}" -eq 1 ] && [ "${claude_watch_rolling_history[1]}" -eq 0 ] \
    && [ "${claude_watch_rolling_history[2]}" -eq 1 ] && [ "${claude_watch_rolling_history[3]}" -eq 1 ]; then
    ok "rolling_window_record: custom-window-override (1,1,0,1,1 / window=4) -> eviction boundary moves correctly"
else
    not_ok "rolling_window_record: custom-window-override (1,1,0,1,1 / window=4) -> eviction boundary moves correctly (got failures=$claude_watch_rolling_failures history=[${claude_watch_rolling_history[*]}])"
fi

# =====================================================================
# claude_watch_trial_signoff_valid() tests
# =====================================================================
#
# Uses an isolated scratch git repo (not the real project repo) so these
# tests never stage, commit, or otherwise mutate this repository's actual
# git state. PROJECT_DIR/SCRIPT_DIR point at the scratch repo for the
# duration of this section only.

SIGNOFF_TEST_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t signoff_test)"
trap 'rm -rf "$SIGNOFF_TEST_DIR"' EXIT

mkdir -p "$SIGNOFF_TEST_DIR/scripts/core" "$SIGNOFF_TEST_DIR/memories"
git -C "$SIGNOFF_TEST_DIR" init -q
git -C "$SIGNOFF_TEST_DIR" config user.email "test@example.com"
git -C "$SIGNOFF_TEST_DIR" config user.name "Test"
echo "# fixture auto-loop.sh v1" > "$SIGNOFF_TEST_DIR/scripts/core/auto-loop.sh"
git -C "$SIGNOFF_TEST_DIR" add scripts/core/auto-loop.sh
git -C "$SIGNOFF_TEST_DIR" commit -q -m "fixture commit"
SIGNOFF_COMMITTED_SHA=$(git -C "$SIGNOFF_TEST_DIR" log -1 --format=%H -- scripts/core/auto-loop.sh)

PROJECT_DIR="$SIGNOFF_TEST_DIR"
SCRIPT_DIR="$SIGNOFF_TEST_DIR/scripts/core"
SIGNOFF_MARKER="$SIGNOFF_TEST_DIR/memories/claude-watch-trial-signoff.md"

# --- Case 1: missing marker -> not approved ---
rm -f "$SIGNOFF_MARKER"
if ! claude_watch_trial_signoff_valid; then
    ok "claude_watch_trial_signoff_valid: missing marker -> not approved"
else
    not_ok "claude_watch_trial_signoff_valid: missing marker -> not approved"
fi

# --- Case 2: malformed marker (missing signoff_cycle) -> not approved ---
printf 'approved_sha: %s\nimplementation_cycle: 28\n' "$SIGNOFF_COMMITTED_SHA" > "$SIGNOFF_MARKER"
if ! claude_watch_trial_signoff_valid; then
    ok "claude_watch_trial_signoff_valid: malformed marker (missing field) -> not approved"
else
    not_ok "claude_watch_trial_signoff_valid: malformed marker (missing field) -> not approved"
fi

# --- Case 3: same-cycle (implementation_cycle == signoff_cycle) -> not approved ---
printf 'approved_sha: %s\nimplementation_cycle: 30\nsignoff_cycle: 30\n' "$SIGNOFF_COMMITTED_SHA" > "$SIGNOFF_MARKER"
if ! claude_watch_trial_signoff_valid; then
    ok "claude_watch_trial_signoff_valid: implementation_cycle == signoff_cycle -> not approved"
else
    not_ok "claude_watch_trial_signoff_valid: implementation_cycle == signoff_cycle -> not approved"
fi

# --- Case 4: stale SHA (approved_sha does not match committed SHA) -> not approved ---
printf 'approved_sha: 0000000000000000000000000000000000000000\nimplementation_cycle: 28\nsignoff_cycle: 30\n' > "$SIGNOFF_MARKER"
if ! claude_watch_trial_signoff_valid; then
    ok "claude_watch_trial_signoff_valid: stale/mismatched approved_sha -> not approved"
else
    not_ok "claude_watch_trial_signoff_valid: stale/mismatched approved_sha -> not approved"
fi

# --- Case 5: valid marker, matching SHA, distinct cycles, clean tree -> approved ---
printf 'approved_sha: %s\nimplementation_cycle: 28\nsignoff_cycle: 30\n' "$SIGNOFF_COMMITTED_SHA" > "$SIGNOFF_MARKER"
if claude_watch_trial_signoff_valid; then
    ok "claude_watch_trial_signoff_valid: valid marker + matching committed SHA + clean tree -> approved"
else
    not_ok "claude_watch_trial_signoff_valid: valid marker + matching committed SHA + clean tree -> approved"
fi

# --- Case 6: staged-but-uncommitted edit to the target file after signoff -> not approved ---
# Regression case for a real bug qa-bach found in cycle #30 review: a plain
# `git diff --quiet` (no ref) compares against the index, not HEAD, so a
# staged-but-uncommitted edit left current_sha (from `git log`) unchanged AND
# made the "no uncommitted changes" check pass -- silently approving code that
# was never actually reviewed. Must use `git diff --quiet HEAD --`.
echo "# fixture auto-loop.sh v2 (uncommitted edit)" >> "$SIGNOFF_TEST_DIR/scripts/core/auto-loop.sh"
git -C "$SIGNOFF_TEST_DIR" add scripts/core/auto-loop.sh
if ! claude_watch_trial_signoff_valid; then
    ok "claude_watch_trial_signoff_valid: staged-but-uncommitted edit after signoff -> not approved"
else
    not_ok "claude_watch_trial_signoff_valid: staged-but-uncommitted edit after signoff -> not approved (BUG: fails open on staged changes)"
fi
git -C "$SIGNOFF_TEST_DIR" reset -q "$SIGNOFF_TEST_DIR/scripts/core/auto-loop.sh"
git -C "$SIGNOFF_TEST_DIR" checkout -q -- "$SIGNOFF_TEST_DIR/scripts/core/auto-loop.sh"

# --- Case 7: CRLF + trailing whitespace in marker fields still parses correctly -> approved ---
printf 'approved_sha: %s  \r\nimplementation_cycle: 28\r\nsignoff_cycle: 30\r\n' "$SIGNOFF_COMMITTED_SHA" > "$SIGNOFF_MARKER"
if claude_watch_trial_signoff_valid; then
    ok "claude_watch_trial_signoff_valid: CRLF + trailing whitespace in marker fields -> still approved"
else
    not_ok "claude_watch_trial_signoff_valid: CRLF + trailing whitespace in marker fields -> still approved"
fi

rm -f "$SIGNOFF_MARKER"
rm -rf "$SIGNOFF_TEST_DIR"
trap - EXIT

# =====================================================================
# Summary
# =====================================================================
total=$((pass_count + fail_count))
echo "1..$total"
echo "# $pass_count/$total passed"

if [ "$fail_count" -eq 0 ]; then
    exit 0
else
    exit 1
fi
