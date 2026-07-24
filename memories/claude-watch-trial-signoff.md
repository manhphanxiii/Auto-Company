# Claude-Watch Trial Signoff (governance record)

This file is a tracked governance marker, deliberately NOT gitignored (unlike
`docs/*/*`). It is read at startup by `claude_watch_trial_signoff_valid()` in
`scripts/core/auto-loop.sh`, which gates whether `AUTO_LOOP_USE_CLAUDE_WATCH=1`
is honored. Do not hand-edit the fields below outside of a review cycle that
re-runs the go/no-go pass described here — editing `approved_sha` without a
fresh signoff defeats the entire purpose of this mechanism.

## Parsed fields (do not reorder or rename)

approved_sha: f7720345b368f5b9ec98d92f275b3f4c740cf1de
implementation_cycle: 28
signoff_cycle: 32

## Cycle #32 re-signoff (distinct-cycle refresh, not a new investigation)

Cycle #31 committed `f772034` ("fix(auto-loop): root-cause the recurring
.gitignore drift bug"), which changed `auto-loop.sh`'s SHA and invalidated
the prior `approved_sha` (`d73f5f8`) by this marker's own design. Cycle #32
re-ran the same bounded question ("is the 5-cycle/3-hour trial still safe to
attempt, now against `f772034`") as two independent, blind passes:

- **critic-munger**: GO. Independently ran `git diff d73f5f8 f772034 --
  scripts/core/auto-loop.sh` and confirmed the entire diff is confined to
  `restore_gitignore_if_changed()`/`snapshot_gitignore()` — a compare-against-
  pre-cycle-snapshot bug fixed to compare-against-`HEAD` instead. Grepped for
  `pgid_matches_expected`, `rolling_window_record`, `terminate_process_group`,
  and threshold/backstop tokens: zero hits in the diff. Ran
  `tests/test_auto_loop_hardening.sh` directly: 24/24 pass, including all
  pgid-reuse and rolling-window cases.
- **qa-bach**: GO on the code at `f772034` (same diff/test verification,
  independently reproduced). **But surfaced a bigger problem**: the live
  orchestrator daemon (PID 63637) has been running continuously since
  **before cycle #28's commit** (`fa1ae0d`) — confirmed by comparing the
  daemon's process start time against `fa1ae0d`/`7e696b7`/`d73f5f8`/`f772034`
  commit timestamps, all of which postdate daemon start. Bash does not
  reload an already-running script's function bodies from disk. **This
  means the currently-running daemon has never loaded the pgid-reuse guard,
  the rolling-window kill-switch, the signoff gate, or the `.gitignore` HEAD
  fix — regardless of what's committed.** The uncommitted `.gitignore` drift
  observed at the start of cycle #32 is this same daemon reverting to its
  pre-cycle-28 snapshot every cycle, not a new bug.

**Net verdict**: the code at `f772034` is safe to trial (GO, confirmed
independently twice). **The current live daemon is NOT running that code**
and must be restarted (fresh bash process) before either the trial or any
of cycles #28-31's hardening takes effect at all. This is a distinct,
higher-priority problem than "can the trial start" — see
`memories/consensus.md` Cycle #32 for the elevated Next Action. Cycle #32's
own agent (this review) is itself a child process of the stale daemon
(confirmed via process ancestry: PID chain 63637 → 14655 → 14658 → claude),
so stopping/restarting it is intentionally left as a human action, not
attempted autonomously — consistent with cycle #30's original reasoning
against an in-cycle bootstrap of infrastructure the reviewing cycle runs
inside of.

## What was actually reviewed, and by whom

- **Implementation cycle #28** (`fa1ae0d`): pgid-reuse guard
  (`pgid_matches_expected()`) + rolling-window kill-switch
  (`rolling_window_record()`), the core reliability mechanisms this trial is
  about.
- **Cycle #29** (`7e696b7`): committed regression tests for both mechanisms,
  independently reviewed by qa-bach (adversarial: injected real regressions,
  confirmed the suite catches them).
- **Cycle #30 (this signoff)**: two independent, blind passes answering the
  specific question "is a bounded first trial of `AUTO_LOOP_USE_CLAUDE_WATCH=1`
  safe to attempt now" (not another implementation-adjacent review):
  - **critic-munger**: GO. No new path to data loss/runaway resource use;
    the known escaped-daemon/setsid gap and mid-git-operation SIGKILL risk
    are pre-existing and symmetric with the legacy watchdog, not introduced
    by this flag. Recommended bounds: 5 cycles / 3 hours, one-shot env var
    (never baked into the launchd plist), hard-stop-and-inspect (not
    silent-fallback) on any GUARD line / exit-3-4 / backstop-fire / orphan
    `ps` hit.
  - **qa-bach**: GO. Identified the log-reconstruction gap (no per-cycle
    indicator of whether claude-watch was active) and the
    delayed-return/orphan race as the one risk class unit tests structurally
    cannot cover. Recommended the same 5-cycle cap, plus a manual `ps` check
    and `backstop`/`GUARD` grep after each cycle, plus recording the outcome
    in `consensus.md` before any extension.
  - Both independently converged on: **5 cycles or 3 hours, whichever comes
    first; abort (revert flag to 0) immediately, not wait-and-see, on any
    single kill-switch trip, backstop occurrence, exit-3/4 detection, or
    orphaned process found via `ps`.**

## Note on `approved_sha` vs. the cycle-28/29 reviewed code

`approved_sha` (`d73f5f8`) is the commit that ALSO adds this governance gate
function and the per-cycle `claude_watch:` observability tags (cycle #30's
own commit). That diff is verified byte-for-byte non-functional relative to
`7e696b7` for every mechanism actually under trial-safety review above
(`pgid_matches_expected`, `rolling_window_record`, `terminate_process_group`,
the auto-disable thresholds, the backstop timer are untouched — confirmed via
`git diff` and the unchanged 13/13 original test results). The gate and
observability additions themselves underwent ordinary same-cycle code review
(qa-bach, adversarial: found and fixed 2 real bugs — a self-referential `git
diff` blind spot to staged-but-uncommitted edits, and observability tags
reading the live kill-switch-mutated variable instead of the per-cycle
snapshot) — the same cadence cycles #28/29 used for their own work. This is
NOT being treated as satisfying the distinct-cycle trial-safety signoff
requirement for anything beyond itself: the distinct-cycle signoff above is
about whether the underlying claude-watch reliability mechanisms (unchanged
by this commit) are safe to trial, and cycle #30 is genuinely distinct from
their cycle #28 implementation.

Any future edit to `scripts/core/auto-loop.sh` will change its SHA and
invalidate this marker (by design) until a fresh distinct-cycle signoff pass
records a new `approved_sha`.

## Trial execution status

Not yet started as of cycle #32. Blocked on a human daemon restart (see
Cycle #32 re-signoff section above) — the current live daemon predates
cycle #28 and is not running any of the reviewed code. See
`memories/consensus.md` Next Action for the exact mechanical steps to stop
the stale daemon, restart it, and then flip `AUTO_LOOP_USE_CLAUDE_WATCH=1`
for the bounded trial described above.
