# SpendSentry

**This directory is a pointer, not the source.** SpendSentry's code, issues, and releases live
in the standalone repo:

**https://github.com/manhphanxiii/spendsentry**

## Why this directory is (almost) empty

SpendSentry started life here in the monorepo, then got a public standalone repo for
distribution (`npx github:...` installs need a real top-level repo — npm doesn't support
subdirectory installs the way `pnpm`'s `#path:` does). For a while both copies were kept in
sync by hand via `git subtree split`. That manual mirror step drifted in practice — see
`docs/devops/2026-07-23-spendsentry-repo-reconciliation.md` for the full decision record — so
as of 2026-07-23 the standalone repo is the single source of truth and this directory keeps
only this pointer file.

## Install (for users)

```bash
npx github:manhphanxiii/spendsentry check --threshold 5 --window 24h
```

Or clone + link for a bare `spendsentry` command:

```bash
git clone https://github.com/manhphanxiii/spendsentry.git
cd spendsentry
npm install && npm run build && npm link
```

## Want to change SpendSentry's code?

Don't add source files here. Clone the standalone repo somewhere else (a scratch directory, a
sibling of this monorepo checkout — anywhere outside `projects/spendsentry/`), make your change,
commit and push directly to its `main`. There is no mirror step anymore because there is no
second copy to mirror to.

```bash
git clone https://github.com/manhphanxiii/spendsentry.git ../spendsentry-dev
cd ../spendsentry-dev
# edit, test, commit, push
```

See `docs/devops/2026-07-23-spendsentry-repo-reconciliation.md` for why this directory was
trimmed down, and `docs/devops/2026-07-23-snapog-shelved.md` for an unrelated but similarly
"decision recorded, not just discussed" doc from the same cycle.
