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

## Menu bar and popup layout

The menu bar must stay compact: each connected provider’s transparent logo followed by `5h%/weekly%` (remaining percentages, in that order). Keep labels, automatic reset times and other detail in the popup or tooltip, not in the visible menu-bar item. Preserve the user’s saved menu-bar position.

The human does not want scrolling inside the menu popup. Keep both provider summaries side by side, with compact usage windows and reset expiry rows. Long descriptions, additional/model limits, historical values, large inventories and reset-recovery status belong in the separate resizable Details window. Preserve access to every reported field and the existing reset confirmation safeguards.

## Data and credential rules

- Unknown, unavailable, or malformed data must stay unknown; never turn it into zero usage, full availability, or zero credits.
- Cached data belongs in the historical section with its original timestamp. Never show it as current in the dashboard or menu bar. Expired windows require a fresh reading.
- QuotaBar monitoring sends read-only control requests: no user/model prompts, purchases, subscription changes, custom token refresh, or direct credential reads/writes. Official CLIs manage their own saved authentication; background monitoring must never start sign-in.
- The human explicitly authorized manual reset capability. Codex redemption is allowed only after its own in-app confirmation, targets a specific account/credit, and must persist/reuse its idempotency key after uncertain results. Never automatically submit, retry, resume, or replay a reset, including after app restart. Claude resets hand off to the official Usage page for confirmation; do not invent an undocumented redemption call.
- **Never exercise a reset action or send a live reset request during development or verification. The human explicitly forbids testing resets or spending any reset credits. Compile and statically review changes only unless the human changes this instruction.**
- Only an explicit user-triggered action may start official Claude Code sign-in. Normal saved authentication stays with that CLI. Do not add custom OAuth token refresh, directly read tokens, or scrape encrypted browser/Desktop credential stores.
- Automatically reuse Claude Code’s saved sign-in at startup and refresh, like Codex. The connection window checks it automatically; do not reintroduce a separate “Use existing sign-in” choice or equate missing usage with missing login. Browser login stays an explicit user action. A bounded, read-only `claude auth status` check may classify failures using only its method/exit status; unknown or unsupported status, service/version errors and stale data must offer retry rather than require sign-in. Never log raw authentication-status output.
- Do not reintroduce QuotaBar Keychain queries or direct authenticated Claude HTTP calls. Use `ClaudeCLIReader`: only initialize, get_binary_version, and get_usage; always skip_behaviors=true to avoid conversation-history scanning. Never send a user turn or auth token. Never change ACLs or signing requirements to bypass trust. Do not log raw CLI replies, credentials, private authorization URLs, or account identifiers.
- Claude CLI usage can come from a cache. Preserve its account-matched fetchedAtMs from non-secret cachedUsageUtilization metadata; missing provenance or samples older than two minutes must not supply current menu percentages.
- Never commit runtime caches, downloaded helper binaries, local account data, app bundles, or credential files. Use synthetic test fixtures.
- Respect request throttling and backoff. Do not repeatedly probe live endpoints while testing parsers.
- Claude's get_usage interface is experimental and its optional reset-grant fields are undocumented. Keep parsing defensive and distinguish implemented schema support from verified live behavior.

## Current verification limits

Local validation has covered Codex live usage, earlier parser/freshness tests, exporter privacy, opening the Claude sign-in flow, and the Claude 2.1.309 read-only usage control protocol with zero model cost. The current CLI helper returned no eligible subscription windows. The 1.7.0 app and test targets were compiled without running tests. End-to-end live Claude usage and optional reset-credit fields still need confirmation after successful account authorization. Do not describe those as verified until observed. The optional exporter is never installed automatically.

For public distribution, account connection reliability, real-provider parity, Developer ID signing/notarization, and release/update handling remain to be completed. No public-release license has been selected.
