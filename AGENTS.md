# Working on QuotaBar

QuotaBar is a native macOS 14+ menu bar app. Both Codex and Claude are first-class providers: preserve five-hour and weekly usage, scheduled reset times, and reset-credit inventory with expiry dates wherever the provider actually reports them.

## Start here

- Read `README.md` for connection behavior, data sources, and current limitations.
- `Sources/QuotaCore/` contains Foundation-only models, parsers, freshness rules, backoff, and sign-in validation.
- `Sources/QuotaBar/` contains the SwiftUI/AppKit UI, provider clients, and official Claude helper integration.
- `Tests/QuotaCoreTests/` uses synthetic fixtures. `scripts/` contains the app build and optional sanitized status-line exporter.

## Build and verify

Run from the repository root on macOS with Xcode/Swift 5.9+:

```sh
./scripts/build.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift test --disable-sandbox
python3 scripts/test-statusline-export.py
codesign --verify --deep --strict dist/QuotaBar.app
```

The build produces `dist/QuotaBar.app` with an ad-hoc signature. It is not a notarized public release. Set `QUOTABAR_BUILD_PATH` to put build intermediates elsewhere if needed.

## Data and credential rules

- Unknown, unavailable, or malformed data must stay unknown; never turn it into zero usage, full availability, or zero credits.
- Cached data belongs in the historical section with its original timestamp. Never show it as current in the dashboard or menu bar. Expired windows require a fresh reading.
- Background monitoring is read-only: no prompts, purchases, subscription changes, background token refresh, or credential writes.
- The human explicitly authorized manual reset capability. Codex redemption is allowed only after its own in-app confirmation, targets a specific account/credit, and must persist/reuse its idempotency key after uncertain results. Never automatically submit, retry, resume, or replay a reset, including after app restart. Claude resets hand off to the official Usage page for confirmation; do not invent an undocumented redemption call.
- **Never exercise a reset action or send a live reset request during development or verification. The human explicitly forbids testing resets or spending any reset credits. Compile and statically review changes only unless the human changes this instruction.**
- Only an explicit user-triggered official Claude Code sign-in helper may save its own credentials. Do not add custom OAuth token refresh or scrape encrypted browser/Desktop credential stores.
- Background Keychain reads must suppress both modern authentication and legacy login-keychain UI, reuse approved access tokens only in memory, and pause further queries after an access failure. Only the explicit Use existing sign-in action may allow a QuotaBar permission dialog; automatic post-login verification remains silent. Do not change ACLs or use an identifier-only signing requirement to bypass trust. Background Keychain reads must not prompt. Keep bearer tokens, cookies, authorization URLs with private query parameters, and account identifiers out of logs, diagnostics, fixtures, screenshots, and commits.
- Never commit runtime caches, downloaded helper binaries, local account data, app bundles, or credential files. Use synthetic test fixtures.
- Respect request throttling and backoff. Do not repeatedly probe live endpoints while testing parsers.
- Claude's OAuth usage/reset-grant fields are undocumented. Keep parsing defensive and distinguish implemented schema support from verified live behavior.

## Current verification limits

Local validation has covered Codex live usage, parser/freshness tests, exporter privacy, and opening the real Claude sign-in flow. End-to-end live Claude usage and optional reset-credit fields still need confirmation after successful account authorization. Do not describe those as verified until observed. The optional exporter is never installed automatically.

For public distribution, account connection reliability, real-provider parity, Developer ID signing/notarization, and release/update handling remain to be completed. No public-release license has been selected.
