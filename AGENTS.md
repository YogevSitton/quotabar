# Working on QuotaBar

QuotaBar is a native macOS 14+ menu bar app. Both Codex and Claude are first-class providers: preserve five-hour and weekly usage, scheduled reset times, and reset-credit inventory with expiry dates wherever the provider actually reports them.

## Start here

- Read `README.md` for connection behavior, data sources, and current limitations.
- `Sources/QuotaCore/` contains Foundation-only models, parsers, freshness rules, backoff, and sign-in validation.
- `Sources/QuotaBar/` contains the SwiftUI/AppKit UI, provider clients, and official Claude helper integration.
- `Tests/QuotaCoreTests/` uses synthetic fixtures. `scripts/` contains the app build and optional sanitized status-line exporter.

## Development workflow

A personal tool was used during development. It is not an app dependency or required to build a fresh clone.

Follow the Git workflow in `CONTRIBUTING.md`:

- Never commit or push to `main`. Work on a branch, preferably named `<type>/<short-topic>` (tool-generated names are fine), and open a pull request.
- Title the pull request as a Conventional Commit (`fix(claude): ...`, `feat(popup): ...`); it becomes the squash-merged commit on `main`.
- Add an Unreleased entry to `CHANGELOG.md` for user-visible changes.
- Do not create tags, releases or version bumps unless the maintainer asks for a release.
- Do not merge a pull request unless the maintainer asks.

## Build and verify

Run from the repository root on macOS with Xcode/Swift 5.9+:

```sh
./scripts/build.sh
swift build --build-tests --disable-sandbox
python3 scripts/audit-public-tree.py --public-docs
codesign --verify --deep --strict dist/QuotaBar.app
```

The build produces `dist/QuotaBar.app` with an ad-hoc signature. It is not a notarized public release. Set `QUOTABAR_BUILD_PATH` to put build intermediates elsewhere if needed.

## User-facing text

Use the ASCII hyphen `-` for every authored dash, including missing-value placeholders, headings, tooltips, alerts, help text and documentation. Do not use long Unicode dashes. Preserve this convention in future changes.

## Menu bar and popup layout

The menu bar must stay compact: each connected provider’s transparent logo followed by `5h%/weekly%` (remaining percentages, in that order). A current no-limit state supported by provider evidence shows neutral `∞` in the 5h position and **No 5-hour limit** in the popup, with no five-hour meter or reset time. An exhausted 5h window shows its reset countdown in place of `0%` (`2h13m/45%`); an exhausted weekly window shows only the weekly countdown. Each percentage blends from the plain label color toward red between 50% and 10% left; countdowns stay uncolored. When a current reading reports a manual reset expiring within 3 days, a small chip after that provider's percentages shows the soonest one's time left, rounded down: orange with days (`2d`), then red with hours or minutes (`18h`, `45m`) in the last 24 hours. It is the only reset detail in the visible item; its space is always reserved so it never changes the item's width, and the tooltip carries the next expiry date. Do not add a More usage limits button to the popup. Keep labels, automatic reset times and other detail in the popup or tooltip, not in the visible menu-bar item. Preserve the user’s saved menu-bar position. Percentage changes and no-limit/unavailable transitions must not resize the status item. Let AppKit place the popup from its precomputed content size; do not reintroduce manual or deferred window-origin corrections or repeatedly reapply unchanged sizes. The popup height is measured from its content (no empty space at the bottom). While it is open, change only `popover.contentSize`; setting the hosting view frame directly leaves the popover chrome at its old height and clips the top. Reset and expiry times carry their countdown in parentheses on the same line, such as `Sun 25 Oct at 10:00 (1d:1h)`; the timezone stays in the tooltip. Claude cards omit the Updated time.

Do not show a generic Details button when it only repeats the visible data. Use contextual links for historical readings, reset overflow and recovery; there is no menu entry for the Details window and it does not show additional/model limits or extra usage (the maintainer dropped them). The header holds only Quit (power) and a More (ellipsis) menu, in that order, with clear top/bottom breathing room; there is no Refresh button (polling is automatic every minute and on wake), Options menu or footer. The ellipsis menu holds a Launch at login checkmark; there is no Settings window. Do not add a Switch Claude account button (QuotaBar follows Claude Code's own sign-in) or a manual Codex CLI picker (detection covers the usual install folders). Manual-reset rows show their exact expiry with its countdown in parentheses, without a redundant total badge; retain underlying credit counts for validation and count-only inventories. Popup expiry warnings use the same tiers as the menu bar chip: orange within 3 days, red within 24 hours. Do not add system notifications for expiring resets; the maintainer does not want them.

The maintainer does not want scrolling inside the menu popup. Keep both provider summaries side by side, with compact usage windows and reset expiry rows. Long descriptions, historical values, large inventories and reset-recovery status belong in the separate resizable Details window. Additional/model limits and extra usage are parsed but intentionally not shown. Preserve the existing reset confirmation safeguards.

## Data and credential rules

- Unknown, unavailable, or malformed data must stay unknown; never turn it into zero usage, full availability, or zero credits.
- Keep measured windows, supported no-limit states and unknown data distinct. Classifying Codex as having no five-hour limit requires the current `pro` plan, exactly one valid weekly-duration window and an explicit null in the other slot; slot order does not matter. Claude has no supported no-limit state: its undocumented `five_hour: null` stays unavailable. Do not add one without documented or live-verified provider evidence. Missing keys, malformed values, other Codex plans and all-null responses are not evidence of no limit. A reported five-hour window takes precedence. See `docs/PROVIDER-INTEGRATIONS.md`.
- Cached data belongs in a clearly labeled Saved reading/historical section with its original timestamp; keep that section visible during transient Claude failures rather than making the previous reading disappear. Never show it as current in the dashboard or menu bar. Expired windows require a fresh reading.
- QuotaBar monitoring sends read-only control requests: no user/model prompts, purchases, subscription changes, custom token refresh, or direct credential reads/writes. Official CLIs manage their own saved authentication; background monitoring must never start sign-in.
- The maintainer explicitly authorized manual reset capability. Codex redemption is allowed only after its own in-app confirmation, targets a specific account/credit, and must persist/reuse its idempotency key after uncertain results. Never automatically submit, retry, resume, or replay a reset, including after app restart. Claude resets hand off to the official Usage page for confirmation; do not invent an undocumented redemption call.
- **Never exercise a reset action or send a live reset request during development or verification. The maintainer explicitly forbids testing resets or spending any reset credits. Compile and statically review changes only unless the maintainer changes this instruction.**
- Only an explicit user-triggered action may start official Claude Code sign-in. Normal saved authentication stays with that CLI. Do not add custom OAuth token refresh, directly read tokens, or scrape encrypted browser/Desktop credential stores.
- Automatically reuse Claude Code’s saved sign-in at startup and refresh, like Codex. The Connect Claude button checks it and proceeds directly to browser login only when required; do not add an intermediate one-button window. Keep progress, cancel and errors in the popup, with a separate window only for optional help/account management; do not reintroduce a separate “Use existing sign-in” choice or equate missing usage with missing login. Browser login stays an explicit user action. A bounded, read-only `claude auth status` check may classify failures using only its method/exit status; unknown or unsupported status, service/version errors and stale data must offer retry rather than require sign-in. Never log raw authentication-status output.
- Do not reintroduce QuotaBar Keychain queries or direct authenticated Claude HTTP calls. Use `ClaudeCLIReader`: only initialize, get_binary_version, and get_usage; always skip_behaviors=true to avoid conversation-history scanning. Never send a user turn or auth token. Never change ACLs or signing requirements to bypass trust. Do not log raw CLI replies, credentials, private authorization URLs, or account identifiers.
- Claude CLI usage can come from a cache. Preserve its account-matched fetchedAtMs from non-secret cachedUsageUtilization metadata; missing provenance or samples older than two minutes must not supply current menu percentages.
- Never commit runtime caches, downloaded helper binaries, local account data, app bundles, or credential files. Use synthetic test fixtures.
- Keep Claude reads scheduled at their exact next eligible time instead of dropping an early periodic tick for a whole interval. Transient usage failures retry automatically with a one-to-five-minute backoff, preserving explicitly labeled saved values. Refresh is fixed at one minute (Claude Code caches usage for 60 seconds); respect request throttling and backoff. Do not repeatedly probe live endpoints while testing parsers.
- Claude's get_usage interface is experimental and its optional reset-grant fields are undocumented. Keep parsing defensive and distinguish implemented schema support from verified live behavior.

## Current verification limits

Local validation has covered Codex live usage, Claude browser sign-in launch, earlier parser/freshness tests and exporter privacy, and the Claude 2.1.309 read-only control protocol with zero model cost. After the maintainer signed in, 1.7.11 displayed live Claude five-hour/weekly values and the reported weekly reset, then refreshed them automatically across several minute boundaries without the agent clicking Retry. Both provider cards and reset expiry countdowns were visually checked, with no popup scrolling. App and test targets compiled; tests were not executed. Claude's optional reset-credit fields and actual redemption behavior remain unverified. No reset action or confirmation was exercised and no reset credit was consumed. The optional exporter is never installed automatically.

On 27 October 2026, one explicitly requested read-only Codex CLI query confirmed the current Pro shape: a valid weekly primary window and a null secondary window. Only sanitized shape information was printed. Official documentation and static inspection of the official 2.1.310 helper established no meaning for Claude's `five_hour: null`, so it stays unavailable. See `docs/VERIFICATION.md` for the change's build and presentation verification status. This one-read authorization does not change the standing restrictions above.

For wider binary distribution, account connection reliability, real-provider parity, Developer ID signing/notarization, and release/update handling remain to be completed. The project uses the MIT License; provider names and marks retain their owners' rights.
