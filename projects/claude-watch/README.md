# claude-watch

**This directory is a pointer, not the source.** claude-watch's code, issues, and releases live
in the standalone repo:

**https://github.com/manhphanxiii/claude-watch**

## Why this directory is (almost) empty

Unlike SpendSentry (Auto Company's first product, which started life in this monorepo and had to
be split out to a standalone repo later — see `projects/spendsentry/README.md` and
`docs/devops/2026-07-23-spendsentry-repo-reconciliation.md` for the full incident), claude-watch
was built directly as a standalone repo from day one. `npx github:owner/repo` doesn't support
subdirectory installs the way `pnpm`'s `#path:` does, so a monorepo subdirectory was never going
to be the source of truth — no reason to repeat the mistake and pay the reconciliation cost twice.

## Install (for users)

```bash
npx github:manhphanxiii/claude-watch run --idle-timeout 5m --max-duration 1h \
  --webhook https://your-endpoint.example.com/hook \
  -- claude -p "do the thing"
```

Or clone + link for a bare `claude-watch` command:

```bash
git clone https://github.com/manhphanxiii/claude-watch.git
cd claude-watch
npm install && npm run build && npm link
```

## Want to change claude-watch's code?

Don't add source files here. Clone the standalone repo somewhere else (a scratch directory, a
sibling of this monorepo checkout — anywhere outside `projects/claude-watch/`), make your change,
commit and push directly to its `main`. There is no mirror step to keep in sync because there is
no second copy.

```bash
git clone https://github.com/manhphanxiii/claude-watch.git ../claude-watch-dev
cd ../claude-watch-dev
# edit, test, commit, push
```

## Origin

Built per the spec in:
- `docs/research/2026-07-24-second-product-discovery.md` (market evidence)
- `docs/ceo/2026-07-24-headless-reliability-godecision.md` (GO decision + v1 scope)
- `docs/cto/2026-07-24-headless-reliability-diligence.md` (architecture spec)
- `docs/critic/2026-07-24-headless-reliability-premortem.md` (binding conditions — note the
  conditions on separating dogfood usage from external validation, and treating distribution
  as unproven; those conditions apply to every future cycle update on this product, not just launch)
- `docs/cfo/2026-07-24-headless-reliability-financials.md` (cost model, leading-indicator thresholds)

Implementation notes: `docs/fullstack/2026-07-24-claude-watch-v1-implementation.md`.
