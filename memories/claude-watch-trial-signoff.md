# Claude-Watch Trial Signoff (governance record)

This file is a tracked governance marker, deliberately NOT gitignored (unlike
`docs/*/*`). It is read at startup by `claude_watch_trial_signoff_valid()` in
`scripts/core/auto-loop.sh`, which gates whether `AUTO_LOOP_USE_CLAUDE_WATCH=1`
is honored. Do not hand-edit the fields below outside of a review cycle that
re-runs the go/no-go pass described here — editing `approved_sha` without a
fresh signoff defeats the entire purpose of this mechanism.

## Parsed fields (do not reorder or rename)

approved_sha: d73f5f802de89b841500412bd0e36582d439eda5
implementation_cycle: 28
signoff_cycle: 30

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

Not yet started as of cycle #30. See `memories/consensus.md` Next Action for
the exact mechanical steps to actually flip `AUTO_LOOP_USE_CLAUDE_WATCH=1` for
the bounded trial described above.
