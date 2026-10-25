## Summary

<!-- What changes, and why. -->

## Verification

- [ ] `./scripts/build.sh` succeeds and leaves Git-tracked files unchanged
- [ ] `swift build --build-tests --disable-sandbox` compiles the test targets without running them
- [ ] No tests or live diagnostics were executed under the current verification restriction
- [ ] `python3 scripts/audit-public-tree.py` passes

What was verified against a live account, if anything, and what still needs one:

## Checklist

- [ ] No reset action was exercised and no reset credit was spent
- [ ] Tests use synthetic fixtures only
- [ ] No tokens, account identifiers, emails or raw CLI output in code, tests, screenshots or this description
- [ ] `docs/VERIFICATION.md` updated if verification status changed
