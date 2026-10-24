# Working on QuotaBar

QuotaBar is a native macOS 14+ menu bar app. Both Codex and Claude are first-class providers: preserve five-hour and weekly usage, scheduled reset times, and reset-credit inventory with expiry dates wherever the provider actually reports them.

## Start here

- Read `README.md` for connection behavior, data sources, and current limitations.
- `Sources/QuotaCore/` contains Foundation-only models, parsers, freshness rules, backoff, and sign-in validation.
- `Sources/QuotaBar/` contains the SwiftUI/AppKit UI, provider clients, and official Claude helper integration.
- `Tests/QuotaCoreTests/` uses synthetic fixtures. `scripts/` contains the app build and optional sanitized status-line exporter.

## personal-tool workflow

This repository is registered locally with personal-tool as `quotabar`, using GitHub's `origin/main` as its base. For work requested through personal-tool, use the installed personal-tool Plan, Review and Build skills in Codex or Claude. personal-tool owns its feature worktrees under the ignored `.personal-tool/worktrees/` directory; do not commit local coordinator state or copy the personal-tool runtime into the app.

The saved project check is `swift build -c release --disable-sandbox` (compilation only). It does not authorize tests, live diagnostics, sign-in or reset actions. Keep the verification restrictions below in every feature plan. personal-tool project registration and app integration are local machine settings, not something a Git clone installs automatically.

## Build and verify

Run from the repository root on macOS with Xcode/Swift 5.9+:

```sh
./scripts/build.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift test --disable-sandbox
python3 scripts/test-statusline-export.py
codesign --verify --deep --strict dist/QuotaBar.app
```

The build produces `dist/QuotaBar.app` with an ad-hoc signature. It is not a notarized public release. Set `QUOTABAR_BUILD_PATH` to put build intermediates elsewhere if needed.

## User-facing text

Use the ASCII hyphen `-` for every authored dash, including missing-value placeholders, headings, tooltips, alerts, help text and documentation. Do not use long Unicode dashes. Preserve this convention in future changes.

## Menu bar and popup layout

The menu bar must stay compact: each connected provider’s transparent logo followed by `5h%/weekly%` (remaining percentages, in that order). An exhausted 5h window shows its reset countdown in place of `0%` (`2h13m/45%`); an exhausted weekly window shows only the weekly countdown. Each percentage blends from the plain label color toward red between 50% and 10% left; countdowns stay uncolored. Do not add a More usage limits button to the popup. Keep labels, automatic reset times and other detail in the popup or tooltip, not in the visible menu-bar item. Preserve the user’s saved menu-bar position. Percentage changes must not resize the status item. Let AppKit place the popup from its precomputed content size; do not reintroduce manual or deferred window-origin corrections or repeatedly reapply unchanged sizes. The popup height is measured from its content (no empty space at the bottom). While it is open, change only `popover.contentSize`; setting the hosting view frame directly leaves the popover chrome at its old height and clips the top. Reset and expiry times carry their countdown in parentheses on the same line, such as `Sun 25 Oct at 10:00 (1d:1h)`; the timezone stays in the tooltip. Claude cards omit the Updated time.

Do not show a generic Details button when it only repeats the visible data. Use contextual links for historical readings, reset overflow and recovery; there is no menu entry for the Details window and it does not show additional/model limits or extra usage (the human dropped them). The header holds Refresh, Settings (gear) and Quit (power) buttons with clear top/bottom breathing room; do not add an Options menu or a footer. The Settings window holds only Launch at login. Do not add a Switch Claude account button (QuotaBar follows Claude Code's own sign-in) or a manual Codex CLI picker (detection covers the usual install folders). Manual-reset rows show their exact expiry with its countdown in parentheses, without a redundant total badge; retain underlying credit counts for validation and count-only inventories.

The human does not want scrolling inside the menu popup. Keep both provider summaries side by side, with compact usage windows and reset expiry rows. Long descriptions, historical values, large inventories and reset-recovery status belong in the separate resizable Details window. Additional/model limits and extra usage are parsed but intentionally not shown. Preserve the existing reset confirmation safeguards.

## Data and credential rules

- Unknown, unavailable, or malformed data must stay unknown; never turn it into zero usage, full availability, or zero credits.
- Cached data belongs in a clearly labeled Saved reading/historical section with its original timestamp; keep that section visible during transient Claude failures rather than making the previous reading disappear. Never show it as current in the dashboard or menu bar. Expired windows require a fresh reading.
- QuotaBar monitoring sends read-only control requests: no user/model prompts, purchases, subscription changes, custom token refresh, or direct credential reads/writes. Official CLIs manage their own saved authentication; background monitoring must never start sign-in.
- The human explicitly authorized manual reset capability. Codex redemption is allowed only after its own in-app confirmation, targets a specific account/credit, and must persist/reuse its idempotency key after uncertain results. Never automatically submit, retry, resume, or replay a reset, including after app restart. Claude resets hand off to the official Usage page for confirmation; do not invent an undocumented redemption call.
- **Never exercise a reset action or send a live reset request during development or verification. The human explicitly forbids testing resets or spending any reset credits. Compile and statically review changes only unless the human changes this instruction.**
- Only an explicit user-triggered action may start official Claude Code sign-in. Normal saved authentication stays with that CLI. Do not add custom OAuth token refresh, directly read tokens, or scrape encrypted browser/Desktop credential stores.
- Automatically reuse Claude Code’s saved sign-in at startup and refresh, like Codex. The Connect Claude button checks it and proceeds directly to browser login only when required; do not add an intermediate one-button window. Keep progress, cancel and errors in the popup, with a separate window only for optional help/account management; do not reintroduce a separate “Use existing sign-in” choice or equate missing usage with missing login. Browser login stays an explicit user action. A bounded, read-only `claude auth status` check may classify failures using only its method/exit status; unknown or unsupported status, service/version errors and stale data must offer retry rather than require sign-in. Never log raw authentication-status output.
- Do not reintroduce QuotaBar Keychain queries or direct authenticated Claude HTTP calls. Use `ClaudeCLIReader`: only initialize, get_binary_version, and get_usage; always skip_behaviors=true to avoid conversation-history scanning. Never send a user turn or auth token. Never change ACLs or signing requirements to bypass trust. Do not log raw CLI replies, credentials, private authorization URLs, or account identifiers.
- Claude CLI usage can come from a cache. Preserve its account-matched fetchedAtMs from non-secret cachedUsageUtilization metadata; missing provenance or samples older than two minutes must not supply current menu percentages.
- Never commit runtime caches, downloaded helper binaries, local account data, app bundles, or credential files. Use synthetic test fixtures.
- Keep Claude reads scheduled at their exact next eligible time instead of dropping an early periodic tick for a whole interval. Transient usage failures retry automatically with a one-to-five-minute backoff, preserving explicitly labeled saved values. Refresh is fixed at one minute (Claude Code caches usage for 60 seconds); respect request throttling and backoff. Do not repeatedly probe live endpoints while testing parsers.
- Claude's get_usage interface is experimental and its optional reset-grant fields are undocumented. Keep parsing defensive and distinguish implemented schema support from verified live behavior.

## Current verification limits

Local validation has covered Codex live usage, Claude browser sign-in launch, earlier parser/freshness tests and exporter privacy, and the Claude 2.1.309 read-only control protocol with zero model cost. After the human signed in, 1.7.11 displayed live Claude five-hour/weekly values and the reported weekly reset, then refreshed them automatically across several minute boundaries without the agent clicking Retry. Both provider cards and reset expiry countdowns were visually checked, with no popup scrolling. App and test targets compiled; tests were not executed. Claude's optional reset-credit fields and actual redemption behavior remain unverified. No reset action or confirmation was exercised and no reset credit was consumed. The optional exporter is never installed automatically.

For public distribution, account connection reliability, real-provider parity, Developer ID signing/notarization, and release/update handling remain to be completed. No public-release license has been selected.
