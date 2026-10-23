# QuotaBar

Native macOS menu bar app for Codex (GPT) and Claude subscription usage. macOS 14 or later; included build is for Apple Silicon. Both providers are required to support 5-hour and weekly usage, scheduled resets, and reset credits with their expiries whenever the provider reports them.

## Project status

Private development preview. Codex live usage and the Claude sign-in launch have been checked locally. Live Claude five-hour/weekly reads have now been checked after account authorization. Optional Claude reset-credit fields still need end-to-end verification. The app is ad-hoc signed and is not yet ready for general public distribution.

For development with either Claude or Codex, read [AGENTS.md](AGENTS.md). No public-release license has been selected.

QuotaBar is registered with the locally installed personal-tool workflow as `quotabar`, based on `origin/main`, with a compile-only project check. Use personal-tool Plan in the lead app and personal-tool Review in the other app when requesting that workflow; Build follows the reviewed plan and its human approval. Local feature worktrees under `.personal-tool/worktrees/` are ignored by Git. personal-tool is development tooling, not an app dependency, and a fresh clone on another Mac needs its own personal-tool installation and project setup.

## Run

Open `dist/QuotaBar.app`. Click its menu bar item to open the usage popup. Clicking outside closes it; reopening the app shows the same popup instead of a separate persistent window.

The popup does not scroll. It uses compact, side-by-side provider cards with the five-hour/weekly meters, automatic reset dates and times with a separate countdown and timezone, up to two short reset rows with expiry dates and Expires in countdowns, without a redundant total count. On shorter screens it reduces the number of inline reset rows; **View all reset offers…** opens the full inventory. A contextual **More usage limits…** link appears only for additional/model limits or extra usage; **Last saved reading…** appears when historical readings are available. Reset overflow and recovery messages have their own contextual links. The redundant always-visible Details button was removed. **Options → Usage details** opens the full resizable view, including reset descriptions (also available as offer-title tooltips). Only that details window scrolls. The popup is sized and laid out before opening; AppKit alone positions it, without deferred window-origin corrections. Unchanged sizes are not reapplied during polling. It sizes against its menu-bar display, reserves edge/arrow margins, and keeps its header controls visible with 20-point top/bottom padding. Options sits beside Refresh in the header; there is no footer. Smaller displays reduce inline reset rows before consuming that space.

The menu bar uses transparent, monochrome vector ChatGPT and Claude marks without app-icon backgrounds. Each provider shows its logo followed by **93%/91%**: five-hour remaining first, weekly remaining second. Automatic reset dates, times and countdowns stay in the popup; hovering over the bar also describes the quotas and reset times. Each provider reserves a fixed-width percentage slot to prevent digit changes from moving the popup anchor. Provider-count changes in the menu bar wait until an open popup closes. QuotaBar remembers its menu-bar position after you Command-drag it. Percentages always mean remaining usage. A dash means a current live value is unavailable. Providers without a detected local installation are hidden and are not polled. Codex detection recognizes its CLI, including the copy bundled in the desktop app. Claude detection recognizes the Desktop app or a standalone Claude Code CLI; QuotaBar's private downloaded sign-in helper alone does not count as an installed provider.

Installed providers appear side by side in the popup. A confirmed missing Claude sign-in or helper shows only **Connect Claude…** in the popup and no menu bar percentages. A usage-service, network, version or cache error instead shows **Live usage unavailable** with **Retry usage**, without treating it as a sign-in problem. The latest account-matched percentages remain visible in a clearly labeled, gray **Saved reading** section with their original time; they never supply current menu percentages. The popup shows when automatic retry is due, so manual Retry is optional. Once live usage is available, its compact card appears with usage windows, reset times, and any reported reset grants. Codex still needs a valid ChatGPT subscription sign-in and a reachable usage service, even when installed. Cached Codex values remain explicitly historical; expired windows never supply current percentages. Dates follow the Mac's timezone, including daylight-saving changes.

The Usage buttons open [ChatGPT usage settings](https://chatgpt.com/settings/usage) and [Claude usage settings](https://claude.ai/settings/usage). Both destinations were checked in a signed-in browser.

## Connect Codex

QuotaBar locates the Codex CLI bundled in ChatGPT/Codex or a standalone installation and reads `account/rateLimits/read` through its local app server. This reuses the existing ChatGPT subscription sign-in. Choose **Options → Locate Codex CLI** if needed. API-key-only authentication does not provide subscription limits.

## Connect Claude

Claude automatically reuses the official CLI’s saved subscription sign-in at startup and on refresh, just like Codex. There is no separate **Use existing sign-in** choice. **Connect Claude** checks the saved sign-in and, only if needed, starts the official browser sign-in directly, without a second native window or another sign-in button. If a helper is missing, this explicit action prepares the verified official helper, then checks the saved login before signing in. Progress, cancellation and errors appear in the popup; **Sign-in help…** opens the optional recovery window for reopening the official authorization page or entering a browser-provided code. **Options → Claude connection…** keeps the advanced status and **Switch Claude account…** actions available. Browser login runs only `auth login --claudeai`; finish authorization yourself. Startup, polling and retrying usage never start browser sign-in.

**QuotaBar no longer reads Keychain credentials or calls Claude's authenticated usage endpoint itself.** Claude Code manages its own normal saved sign-in. macOS may still require Claude Code itself to unlock or access its credentials; QuotaBar does not request that access or alter any Keychain permissions.

The usage reader starts a bounded Claude Code subprocess and sends only these control requests:

- `initialize`
- `get_binary_version`
- `get_usage` with `skip_behaviors: true`

When a usage read fails, a separate bounded `claude auth status` command checks the CLI’s reported authentication method and exit status. Only a confirmed signed-out or incompatible authentication method requests subscription sign-in. Unsupported status output, network/service failures, stale caches and version errors remain usage errors with a retry action. Raw status output stays in memory and is never displayed or logged.

It sends no user prompt, model turn, reset action, or authentication token. Tools, hooks, external MCP servers, project settings, customizations, telemetry, automatic updates, and session persistence are disabled for this reader. Managed policies remain effective. API keys and custom credential environments are not inherited. Do not use `--bare`: it disables subscription OAuth too. The CLI is responsible for its own credential handling; QuotaBar never refreshes or writes credentials itself. Background discovery never downloads a helper or starts browser sign-in.

This uses the experimental `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET` / `get_usage` interface that Anthropic added to its Agent SDK. The current reader requires CLI 2.1.309 or later because that is the locally inspected version with the skip-history behavior verified. Older or incompatible CLIs fail visibly. Claude usage still needs successful subscription authorization before live values can appear.

The result preserves five-hour/weekly usage, scheduled reset times, model windows, and extra usage whenever returned. The CLI is allowed to exit normally after a read so pending cache writes can finish before the sample timestamp is verified. Optional reset grants are parsed only if the CLI actually includes them. Missing grant inventory stays unknown and hidden; full reset-credit parity has not been verified through this route. Claude redemption continues to open the official Usage page for the user's own selection and confirmation.

Claude Code can answer from its own usage cache. QuotaBar reads only the non-secret account metadata and `cachedUsageUtilization` fields in `~/.claude.json`, matches the account and the returned quota windows, and preserves `fetchedAtMs`. It does not stamp an older CLI cache as newly fetched. A sample older than two minutes or one without verifiable provenance cannot supply current menu percentages. In-flight account changes invalidate the result. Transient usage failures retry automatically after one minute, increasing to at most five minutes; authentication/helper failures wait at least five minutes. Configured slower refresh intervals are respected. Explicit connection verification can retry after sign-in.

Verification on 23 October 2026: the local official CLI 2.1.309 accepted initialization, the binary-version request, and `get_usage` with history scanning disabled. It reported zero model cost, zero model API duration, and empty model usage. It returned no eligible subscription windows for the helper's current sign-in, so actual live percentages, reset times, cache matching, and optional grants still need acceptance after browser authorization. Raw CLI output and account identifiers were not logged or saved. On 24 October, after the human completed sign-in, 1.7.11 showed live five-hour/weekly readings and the reported weekly reset; observation times advanced across several automatic refresh cycles without clicking Retry. Optional Claude reset-grant fields remain unverified.

## Refresh and local fallbacks

Network polling defaults to one minute, with five-minute, fifteen-minute, and manual alternatives. This is a client cadence, not a guaranteed provider-supported request quota. Successful Claude CLI usage queries are spaced at least one minute apart even when repeatedly refreshed. This sends up to 60 reads per provider per hour; no model inference requests are made. The former five-minute default migrates to one minute once; other saved cadences are preserved. Claude reads have a dedicated timer at the exact next eligible read time, slightly beyond the CLI’s inspected 60-second cache TTL, so an early shared polling tick cannot skip a full minute. Transient failures use a one-to-five-minute backoff; the CLI owns its internal network throttling and authentication. QuotaBar does not receive or override raw HTTP Retry-After headers through this interface. Both providers refresh after wake. The dashboard and menu share one freshness rule; a past reset time also suppresses that window’s current percentage until a fresh reading arrives.

When Claude's live request is unavailable, the app selects the newest account-matched reading from:

1. The last successful usage response held in memory.
2. An optional Claude Code status-line snapshot.
3. `~/Library/Application Support/Claude/plan-usage-history.json` (version 2).

Disk history contributes percentages only: no reset times, credit counts, or expiries are inferred. Its original sample time is retained, even when it is hours old. Account/organization IDs are read from `~/.claude.json` only to keep readings from different accounts apart. A boolean unused-reset cache is not interpreted as a credit inventory because it cannot supply counts or expiry dates.

### Optional status-line exporter

`scripts/capture-claude-statusline.py` can receive Claude Code's status-line JSON and save only sanitized rate-limit fields, the active organization ID, and the capture time. It creates a private (0600) JSON snapshot at `~/Library/Application Support/QuotaBar/claude-statusline.json` using an atomic replacement. QuotaBar checks for changes every ten seconds and labels the saved reading Cached with its capture time. This requires an active Claude Code session to supply readings.

**The exporter is not installed or configured automatically.** Enabling it changes `~/.claude/settings.json` and requires your explicit consent. If you already use a status-line script, preserve or chain that script instead of replacing it. No Claude settings were changed during this implementation.

## Build, test, diagnostics

Requires Xcode/Swift 5.9 or newer. No external packages or inference API calls are required.

```sh
./scripts/build.sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swift test --disable-sandbox
python3 scripts/test-statusline-export.py
./dist/QuotaBar.app/Contents/MacOS/QuotaBar --check-codex
./dist/QuotaBar.app/Contents/MacOS/QuotaBar --check-claude
```

The Claude diagnostic uses the same control-only CLI reader. There is no QuotaBar Keychain permission mode. Diagnostics print percentages, source/sample time, and safe status messages; never credentials or account identifiers. Exit 2 indicates a fallback or connection issue, not verified live usage.

The app icon represents two quota meters and a fuel-style capacity gauge. Its editable vector drawing is `scripts/draw-app-icon.swift`; `Assets/QuotaBar.pdf` and the provider PDFs preserve the paths, and PNG files are previews. The build regenerates the artwork and standard macOS app-icon sizes, then sets the bundle icon automatically. Provider symbol paths come from the official sites, with provenance in `Assets/ICON.md`. No screenshots are used.

Set `QUOTABAR_BUILD_PATH` to keep build intermediates outside the source directory. The build script produces an ad-hoc signed personal app in `dist/`. For a stable launch-at-login installation, move the app into Applications before enabling that option. This local build is not notarized for distribution.

Tests also verify the helper release URL, manifest size/checksum validation, path-injection rejection, and strict official authorization-link handling. Tests cover the provider contracts, missing versus zero data, malformed values, grant counts and expiries, timestamp formats, account-matched caches, CLI response parsing, missing subscription data, backoff, and exporter privacy. The test suite currently contains 23 Swift tests plus the exporter privacy test. For this update the test targets were compiled, but no tests were executed under the existing verification restriction. Completing browser authorization and comparing both usage windows, reset times, and any reported reset grants against the provider account pages remain manual acceptance checks.

## Use a saved reset

**Codex:** Each supported live reset credit has a **Use reset…** button. It requires a fresh account-verified reading and opens a confirmation with the selected credit, expiry, and current remaining usage. Cancel is the default action. Only clicking **Use 1 reset** authorizes a request. QuotaBar checks the active account and specific credit again before calling the documented `account/rateLimitResetCredit/consume` RPC. It never omits the selected credit ID, buys resets, or selects a different credit automatically. Older/unsupported credits and count-only inventories are managed on the linked ChatGPT Usage page.

Before sending, QuotaBar atomically saves and synchronizes the account, credit, and UUID idempotency key in a private `~/Library/Application Support/QuotaBar/pending-codex-reset.json` recovery record (directory 0700, file 0600). An uncertain result blocks new requests. **Review saved reset request…** requires another confirmation and retries only the original account/credit/key. Restarting the app never replays it. A recognized outcome clears the recovery record and triggers a read-only refresh; balances are never set to 100% locally. An unreadable recovery record disables redemption rather than risking a duplicate. Missing account identity, stale readings, expired credits, and unsupported reset types cannot start a new redemption.

**Claude:** **Use a reset on Claude ↗** opens Claude's official Usage screen, where the user selects and confirms the reset. No undocumented Claude redemption POST is implemented, and opening the page does not consume a reset. The final action remains on Claude's own interface.

**Verification restriction:** The human explicitly forbids exercising reset actions or spending resets during development. This implementation was compiled and statically reviewed only. No reset button, confirmation, mutation request, recovery retry, or reset test was exercised. Actual redemption behavior remains unverified; do not claim otherwise. The existing test suite was not rerun for this change.

## Monitoring and account actions

Background monitoring remains read-only. The only quota mutation is the separately confirmed, user-triggered Codex reset action above. QuotaBar does not send model prompts, purchase credits, change subscription settings, or refresh Claude tokens in the background. Only official Claude Code handles its own saved authentication; QuotaBar neither reads nor writes credential stores and does not modify Claude settings. It reads neither conversation logs nor Claude Desktop credential stores. There are no analytics or hosted backend. Quota snapshots remain in memory except for the separately enabled local status-line exporter; the reset recovery record stores only local recovery metadata, never credentials.

References: [Codex App Server](https://learn.chatgpt.com/docs/app-server), [Claude credential management](https://code.claude.com/docs/en/authentication#credential-management), [Claude status-line usage fields](https://code.claude.com/docs/en/statusline#rate-limit-usage), [Claude reset offers](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset). Optional usage/reset-grant fields remain defensive parser support from the supplied brief, not a promised public API. See [provider integration findings](docs/PROVIDER-INTEGRATIONS.md) for the CLI investigation and Gemini route.

Provider symbols remain the respective providers’ artwork, included only to identify the integrations. Locally rendered vector PDFs are preferred, with installed application artwork and bundled ICNS files as fallbacks.
