<!--
Title this pull request as a Conventional Commit, for example:
  fix(claude): keep saved readings visible during transient failures
It becomes the commit message on main when squash-merged. See CONTRIBUTING.md.
-->

## Summary

<!-- What changes, and why. Link the issue, for example: Closes #12 -->

## Verification

- [ ] `./scripts/build.sh` succeeds and leaves Git-tracked files unchanged
- [ ] `swift build --build-tests --disable-sandbox` compiles the test targets without running them
- [ ] No tests or live diagnostics were executed under the current verification restriction
- [ ] `python3 scripts/audit-public-tree.py --public-docs` passes
- [ ] `codesign --verify --deep --strict dist/QuotaBar.app` passes

What was verified against a live account, if anything, and what still needs one:

## Checklist

- [ ] No reset action was exercised and no reset credit was spent
- [ ] Tests use synthetic fixtures only
- [ ] No tokens, account identifiers, emails, private authorization links or raw CLI output in code, tests, screenshots or this description
- [ ] `CHANGELOG.md` has an Unreleased entry if users would notice this change
- [ ] `docs/VERIFICATION.md` updated if verification status changed
- [ ] AI assistance, if any, is mentioned above
