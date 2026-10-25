# Contributing to QuotaBar

Thanks for helping. QuotaBar reads subscription usage for real accounts, so a few rules matter more than usual. Read [AGENTS.md](AGENTS.md) before changing code: it holds the full project, credential, reset and layout rules, and it applies to human and AI contributors alike.

## Ground rules

- **Never exercise a reset action.** Do not click Use reset, confirm a reset, send a reset request, or spend reset credits while developing or testing, on any account. Review reset changes statically; current verification is compile-only.
- **Use synthetic fixtures only.** Tests must not contact a provider, read a real account, or depend on local caches. Never commit real account identifiers, emails, tokens, raw CLI output, runtime caches, downloaded helper binaries or app bundles.
- **Keep monitoring read-only.** No model prompts, purchases, subscription changes, token refresh or direct credential access.
- **Unknown stays unknown.** Missing or malformed provider data must never become zero usage, full availability or zero credits.
- **Use ASCII hyphens** for every authored dash in UI text and documentation.

## Build and review

Requires macOS 14+ and Xcode/Swift 5.9 or newer.

```sh
./scripts/build.sh
swift build --build-tests --disable-sandbox
python3 scripts/audit-public-tree.py
```

`./scripts/build.sh` must leave Git-tracked files unchanged. If you change the app icon drawing, run `./scripts/build-icon.sh` and commit the regenerated artwork in the same pull request.

Do not execute tests, live diagnostics, sign-in or reset actions under the current verification restriction. The maintainer must explicitly change that restriction first. Never paste raw provider output or identifiers into an issue or pull request.

## Pull requests

- Keep each pull request focused on one change, and describe what you verified and what still needs a live account.
- Add or update synthetic-fixture tests for behavior changes in `Sources/QuotaCore/`.
- Screenshots must not show emails, names, account or organization IDs, or other personal data.
- CI compiles the app and test targets on macOS and audits the public tree; it does not execute tests. Workflows from first-time contributors wait for maintainer approval before running.
- Update `docs/VERIFICATION.md` when a change affects what has or has not been verified.

## Reporting bugs and security issues

Use the issue templates for bugs and feature requests. Report security vulnerabilities privately, as described in [SECURITY.md](SECURITY.md), not in a public issue.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
