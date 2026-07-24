# Human Action Needed

Five items are sitting here because the team is not authorized to do them
autonomously (credentials it doesn't have, a web-UI-only checkbox, or
third-party posting that requires a human check-in per policy). Consensus is
re-read by the loop every cycle but isn't a place a human is likely to look —
this file exists so the ask is visible from the repo root instead of buried
in per-cycle churn. Safe to delete once actioned; nothing in the loop depends
on this file existing.

## 1. Restart the auto-loop daemon

The currently running daemon (PID 63637 as of cycle #34) predates the
hardening work merged in commits `2cf25b1`..`f772034`/`6419bb3` (cycles
#28-33: pgid-reuse guard, rolling-window kill-switch, governance signoff
gate, and the `.gitignore`-drift fix). None of that code is loaded in the
live process.

**This is not theoretical anymore.** Cycle #34 caught the stale daemon
actively re-triggering the exact `.gitignore` drift bug that `f772034` was
supposed to have fixed: the running process still executes the old
snapshot-vs-pre-cycle-snapshot comparison instead of the new
snapshot-vs-HEAD comparison, so it clobbered cycle #33's own legitimate
`.gitignore` commit in the working tree. Caught and reverted this cycle;
will keep recurring every cycle until the daemon is restarted.

```bash
./scripts/core/stop-loop.sh
# confirm stopped:
ps aux | grep auto-loop.sh
# then:
AUTO_LOOP_USE_CLAUDE_WATCH=1 nohup ./scripts/core/auto-loop.sh > logs/trial-cycle-onward.log 2>&1 &
disown
```

This also starts the bounded claude-watch dogfood trial, signed off against
`f772034` in `memories/claude-watch-trial-signoff.md` (cycle #32). Bounds: 5
cycles or 3 hours, whichever comes first; abort on any kill-switch trip,
backstop occurrence, exit-3/4, or orphaned process.

## 2. npm registry credentials for claude-watch and spendsentry

Both tools already work without this (`npx github:manhphanxiii/<tool>` is
documented and functional in both READMEs), so this is upside, not a
blocker to basic usage. It would let `npm install -g claude-watch` /
`npx claude-watch` (unqualified, no `github:` prefix) work, and is a
prerequisite for the GitHub Actions Marketplace listing below.

- Run `npm adduser` (or `npm login`) once on this machine with an npm
  registry account for the `manhphanxiii` org/user, **or**
- Run `gh auth refresh -s write:packages -s read:packages` to grant the
  existing `gh` token package scopes, enabling a GitHub Packages publish
  instead (`npm.pkg.github.com`) — no separate npm account needed.

## 3. GitHub Actions Marketplace listing for claude-watch

`action.yml` already exists and the action works via
`uses: manhphanxiii/claude-watch@v0.1.1` — it's just not listed in the
Marketplace, which only helps discovery. Listing requires a one-time,
web-UI-only step (checking a box on the release page in the GitHub UI)
that the `gh` CLI has no equivalent for. On the release page for `v0.1.1`
(or a future tag), check "Publish this Action to the GitHub Marketplace"
and pick a category (suggest "Utilities" or "Continuous Integration").

## 4. Review and approve the 2 drafted awesome-list submissions

Per CLAUDE.md's safety guardrails, posting to third-party platforms
(including PRs to someone else's awesome-list repo) requires a check-in
before posting, even though the guardrail table doesn't forbid it outright.
Drafts are ready and waiting:

- `docs/marketing/2026-07-24-claude-watch-awesome-list-submissions-draft.md`

Read them, and either approve them for posting (say so, and the team will
open the PRs) or edit them directly.

## 5. Cloudflare (`wrangler`) is not actually authenticated on this machine

CLAUDE.md's tooling table lists `wrangler` as "Available," but as of cycle
#35 `npx wrangler whoami` returns "You are not authenticated," there's no
`CLOUDFLARE_API_TOKEN`/`CF_*` env var, and no cached OAuth session under
`~/.wrangler` or `~/Library/Preferences/.wrangler`. This matters beyond
Cloudflare housekeeping: the team considered deploying an owned Cloudflare
Pages domain as a way to escape the current discovery deadlock (an owned
domain would let us host an IndexNow ownership-verification key and control
our own SEO surface, instead of being stuck under `github.com`'s root, which
we don't control). That idea is dead on arrival until this is fixed — same
credential-gated shape as items #1-3, just discovered later.

- Run `npx wrangler login` (interactive OAuth in a browser) once on this
  machine, **or**
- Set a `CLOUDFLARE_API_TOKEN` env var (scoped to Pages/Workers edit) so the
  team can deploy non-interactively going forward.

Either unblocks Cloudflare Pages/Workers/KV/D1/R2 deployment, which is
currently unavailable despite CLAUDE.md documenting it as ready to use.

---

*Last consolidated: cycle #35, 2026-07-24. If you've actioned an item,
delete its section (or the whole file, once all five are done).*
