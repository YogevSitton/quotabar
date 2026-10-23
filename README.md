# QuotaBar

Native macOS menu bar app for Codex (GPT) and Claude subscription usage. macOS 14 or later; included build is for Apple Silicon. Both providers are required to support 5-hour and weekly usage, scheduled resets, and reset credits with their expiries whenever the provider reports them.

## Project status

Private development preview. Codex live usage and the Claude sign-in launch have been checked locally. Live Claude usage and optional reset-credit fields still need end-to-end verification after successful account authorization. The app is ad-hoc signed and is not yet ready for general public distribution.

For development with either Claude or Codex, read [AGENTS.md](AGENTS.md). No public-release license has been selected.

## Run

Open `dist/QuotaBar.app`. Click its menu bar item to open the usage popup. Clicking outside closes it; reopening the app shows the same popup instead of a separate persistent window.

The menu bar uses the ChatGPT and Claude app icons, each followed by **5h: 93% Weekly: 91%**, for example. Percentages always mean remaining usage. A dash means a current live value is unavailable. Providers without a detected local installation are hidden and are not polled. Codex detection recognizes its CLI, including the copy bundled in the desktop app. Claude detection recognizes the Desktop app or a standalone Claude Code CLI; QuotaBar's private downloaded sign-in helper alone does not count as an installed provider.

Installed providers appear side by side in the popup. An installed but disconnected Claude shows only **Connect Claude…** in the popup and no menu bar percentages. Once live usage is available, its full card appears with usage windows, reset times, and any reported reset grants. Codex still needs a valid ChatGPT subscription sign-in and a reachable usage service, even when installed. Cached Codex values remain explicitly historical; expired windows never supply current percentages. Dates follow the Mac's timezone, including daylight-saving changes.

The Usage buttons open [ChatGPT usage settings](https://chatgpt.com/settings/usage) and [Claude usage settings](https://claude.ai/settings/usage). Both destinations were checked in a signed-in browser.

## Connect Codex

QuotaBar locates the Codex CLI bundled in ChatGPT/Codex or a standalone installation and reads `account/rateLimits/read` through its local app server. This reuses the existing ChatGPT subscription sign-in. Choose **Options → Locate Codex CLI** if needed. API-key-only authentication does not provide subscription limits.

## Connect Claude

Choose **Connect Claude** on the dashboard or in Options. It opens a native setup window immediately; background usage checks cannot disable the setup button.

- **Sign in with Claude** starts the actual sign-in flow and shows its progress. If a trusted standalone Claude Code CLI is already installed, the app uses it. Otherwise it downloads Anthropic's official helper into `~/Library/Application Support/QuotaBar/ClaudeCode`, verifies the published SHA-256 checksum and file size, and uses it there. The first download is currently about 276 MB. It creates no global launcher or shell integration and requires no Terminal setup.
- The helper runs only `auth login --claudeai`, opening Claude's authorization page in your browser. Finish sign-in there. QuotaBar then checks live usage silently. If Keychain permission is needed, choose **Use existing sign-in** yourself; the automatic post-login check cannot summon another QuotaBar permission dialog. If the browser did not open, the setup window offers **Open sign-in page**. A manual authorization-code field is available if Claude asks for one.
- **Use existing sign-in** reads the existing Keychain login and checks usage. macOS may ask whether QuotaBar can read `Claude Code-credentials`; you approve this yourself. Background queries suppress both modern authentication and legacy login-keychain UI. A denied, missing, or unreadable credential pauses further background Keychain queries for the running session until an explicit connection action. An approved access token is reused in memory until expiry, rejection, or an account change, so one-minute usage refreshes do not repeatedly read Keychain. No token copy is written to disk.
- **Cancel** stops the pending helper download or sign-in process. Sign-in failures remain visible with a retry action.

The user-triggered sign-in is handled by Anthropic's official Claude Code helper, which saves its own login normally. QuotaBar's background monitor only reads the saved `claudeAiOauth.accessToken` and expiry. It never refreshes or writes tokens itself. No Claude Desktop encrypted token cache or Chromium cookie database is read.

Development builds use an ad-hoc signature. Its designated requirement is tied to the current binary hash, so rebuilding can invalidate a previous Always Allow decision. Proper, stable certificate signing is needed for reliable trust across updates. Set `QUOTABAR_SIGN_IDENTITY` to an existing appropriate signing identity when building for that purpose; the build never changes Keychain ACLs, creates certificates, or relaxes trust checks automatically. The legacy silent-access compatibility calls are deprecated SDK APIs used deliberately alongside LAContext for macOS login-keychain protection; they are serialized and restore the previous interaction setting.

If the saved sign-in expires or is rejected, choose **Connect Claude** and sign in again. This is an explicit user action, not automatic token refresh. A successful browser sign-in is followed by a live usage check; an incomplete connection is never labelled successful.

The usage request is:

```
GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1
```

Authorization stays in the request header and is never logged or displayed. The client identifies itself as QuotaBar. The `anthropic-beta: oauth-2025-04-20` header follows the supplied integration brief; its requirement is not independently established. These are undocumented interfaces and can change. HTTP redirects are refused so credentials cannot be forwarded to another destination.

When returned, `cedar_ember` supplies individual grants with remaining uses, session/weekly/full type, expiry, usability, next-to-be-used marker, and cooldown. Available totals include only grants with positive `resets_left` and explicit `paused: false`. Missing or malformed grant details stay unknown. **If the block is missing, the Claude credits section is hidden; absence never becomes zero.**

Optional model/surface limits appear under Additional plan limits. Extra-usage amounts are converted from minor units and displayed only when reported, with the reported currency.

## Refresh and local fallbacks

Network polling defaults to one minute, with five-minute, fifteen-minute, and manual alternatives. This is a client cadence, not a guaranteed provider-supported request quota. Claude successful usage reads are spaced at least one minute apart even when repeatedly refreshed. This sends up to 60 reads per provider per hour; no model inference requests are made. The former five-minute default migrates to one minute once; other saved cadences are preserved. Failed calls use increasing backoff; 403 and 429 observe cooldowns, including Retry-After. A rejected token is not retried until the saved token changes. No token refresh is attempted. Both providers refresh after wake. The dashboard and menu share one freshness rule; a past reset time also suppresses that window’s current percentage until a fresh reading arrives.

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

The Claude diagnostic is non-interactive by default. Add `--allow-keychain` only to request a system access prompt. Diagnostics print percentages, source/sample time, and safe status messages; never credentials or account identifiers. Exit 2 indicates a fallback or connection issue, not verified live usage.

The original app icon lives in `Assets/QuotaBar.png`, with its generation prompt in `Assets/ICON.md`. The build script regenerates all standard macOS icon sizes with `scripts/build-icon.sh` and sets the bundle icon automatically.

Set `QUOTABAR_BUILD_PATH` to keep build intermediates outside the source directory. The build script produces an ad-hoc signed personal app in `dist/`. For a stable launch-at-login installation, move the app into Applications before enabling that option. This local build is not notarized for distribution.

Tests also verify the helper release URL, manifest size/checksum validation, path-injection rejection, and strict official authorization-link handling. Tests cover the provider contracts, missing versus zero data, malformed values, grant counts and expiries, timestamp formats, account-matched caches, credential schema/expiry handling, read-only request construction, backoff, and exporter privacy. The test suite currently contains 23 Swift tests plus the exporter privacy test. Completing browser authorization and comparing both usage windows, reset times, and any reported reset grants against the provider account pages remain manual acceptance checks.

## Use a saved reset

**Codex:** Each supported live reset credit has a **Use reset…** button. It requires a fresh account-verified reading and opens a confirmation with the selected credit, expiry, and current remaining usage. Cancel is the default action. Only clicking **Use 1 reset** authorizes a request. QuotaBar checks the active account and specific credit again before calling the documented `account/rateLimitResetCredit/consume` RPC. It never omits the selected credit ID, buys resets, or selects a different credit automatically. Older/unsupported credits and count-only inventories are managed on the linked ChatGPT Usage page.

Before sending, QuotaBar atomically saves and synchronizes the account, credit, and UUID idempotency key in a private `~/Library/Application Support/QuotaBar/pending-codex-reset.json` recovery record (directory 0700, file 0600). An uncertain result blocks new requests. **Review saved reset request…** requires another confirmation and retries only the original account/credit/key. Restarting the app never replays it. A recognized outcome clears the recovery record and triggers a read-only refresh; balances are never set to 100% locally. An unreadable recovery record disables redemption rather than risking a duplicate. Missing account identity, stale readings, expired credits, and unsupported reset types cannot start a new redemption.

**Claude:** **Use a reset on Claude ↗** opens Claude's official Usage screen, where the user selects and confirms the reset. No undocumented Claude redemption POST is implemented, and opening the page does not consume a reset. The final action remains on Claude's own interface.

**Verification restriction:** The human explicitly forbids exercising reset actions or spending resets during development. This implementation was compiled and statically reviewed only. No reset button, confirmation, mutation request, recovery retry, or reset test was exercised. Actual redemption behavior remains unverified; do not claim otherwise. The existing test suite was not rerun for this change.

## Monitoring and account actions

Background monitoring remains read-only. The only quota mutation is the separately confirmed, user-triggered Codex reset action above. QuotaBar does not send model prompts, purchase credits, change subscription settings, or refresh Claude tokens in the background. Only the user-triggered official Claude Code sign-in helper creates or updates its own credentials; the monitoring client does not write Keychain entries or modify Claude settings. It reads neither conversation logs nor Claude Desktop credential stores. There are no analytics or hosted backend. Quota snapshots remain in memory except for the separately enabled local status-line exporter; the reset recovery record stores only local recovery metadata, never credentials.

References: [Codex App Server](https://learn.chatgpt.com/docs/app-server), [Claude credential management](https://code.claude.com/docs/en/authentication#credential-management), [Claude status-line usage fields](https://code.claude.com/docs/en/statusline#rate-limit-usage), [Claude reset offers](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset). The internal OAuth usage/reset-grant contract comes from the user-supplied brief and is not presented as a documented public API.

Provider icons are the respective providers’ artwork, included only to identify the integrations. Installed application artwork is preferred, with bundled icons as fallbacks.
