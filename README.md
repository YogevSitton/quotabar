# QuotaBar

Native macOS menu bar app for Codex (GPT) and Claude subscription usage. macOS 14 or later; included build is for Apple Silicon. Both providers are required to support 5-hour and weekly usage, scheduled resets, and reset credits with their expiries whenever the provider reports them.

## Project status

Private development preview. Codex live usage and the Claude sign-in launch have been checked locally. Live Claude usage and optional reset-credit fields still need end-to-end verification after successful account authorization. The app is ad-hoc signed and is not yet ready for general public distribution.

For development with either Claude or Codex, read [AGENTS.md](AGENTS.md). No public-release license has been selected.

## Run

Open `dist/QuotaBar.app`. The first launch opens a dashboard; closing that window leaves the menu bar item running. Opening the app again shows the dashboard.

The menu label is **C 93/91 · A 82/72**, for example: Codex and Claude, each showing 5-hour / weekly percentage remaining. A dash means there is no current live reading. If a provider is disconnected or its reading has expired, the panel says Live usage unavailable and hides percentages from the current-usage area. Saved values are available only in a collapsed Last saved reading section, with their sample time and age; they are explicitly historical. Open the panel to see percent used, percent remaining, scheduled reset times, countdowns, and available reset grants. Every reading is labelled **Live** or **Cached** with its sample time. Dates follow the Mac's timezone, including daylight-saving changes.

## Connect Codex

QuotaBar locates the Codex CLI bundled in ChatGPT/Codex or a standalone installation and reads `account/rateLimits/read` through its local app server. This reuses the existing ChatGPT subscription sign-in. Choose **Options → Locate Codex CLI** if needed. API-key-only authentication does not provide subscription limits.

## Connect Claude

Choose **Connect Claude** on the dashboard or in Options. It opens a native setup window immediately; background usage checks cannot disable the setup button.

- **Sign in with Claude** starts the actual sign-in flow and shows its progress. If a trusted standalone Claude Code CLI is already installed, the app uses it. Otherwise it downloads Anthropic's official helper into `~/Library/Application Support/QuotaBar/ClaudeCode`, verifies the published SHA-256 checksum and file size, and uses it there. The first download is currently about 276 MB. It creates no global launcher or shell integration and requires no Terminal setup.
- The helper runs only `auth login --claudeai`, opening Claude's authorization page in your browser. Finish sign-in there. QuotaBar then checks live usage automatically. If the browser did not open, the setup window offers **Open sign-in page**. A manual authorization-code field is available if Claude asks for one.
- **Use existing sign-in** reads the existing Keychain login and checks usage. macOS may ask whether QuotaBar can read `Claude Code-credentials`; you approve this yourself. Background polls never open permission dialogs.
- **Cancel** stops the pending helper download or sign-in process. Sign-in failures remain visible with a retry action.

The user-triggered sign-in is handled by Anthropic's official Claude Code helper, which saves its own login normally. QuotaBar's background monitor only reads the saved `claudeAiOauth.accessToken` and expiry. It never refreshes or writes tokens itself. No Claude Desktop encrypted token cache or Chromium cookie database is read.

If the saved sign-in expires or is rejected, choose **Connect Claude** and sign in again. This is an explicit user action, not automatic token refresh. A successful browser sign-in is followed by a live usage check; an incomplete connection is never labelled successful.

The usage request is:

```
GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1
```

Authorization stays in the request header and is never logged or displayed. The client identifies itself as QuotaBar. The `anthropic-beta: oauth-2025-04-20` header follows the supplied integration brief; its requirement is not independently established. These are undocumented interfaces and can change. HTTP redirects are refused so credentials cannot be forwarded to another destination.

When returned, `cedar_ember` supplies individual grants with remaining uses, session/weekly/full type, expiry, usability, next-to-be-used marker, and cooldown. Available totals include only grants with positive `resets_left` and explicit `paused: false`. Missing or malformed grant details stay unknown. **If the block is missing, the Claude credits section is hidden; absence never becomes zero.**

Optional model/surface limits appear under Additional plan limits. Extra-usage amounts are converted from minor units and displayed only when reported, with the reported currency.

## Refresh and local fallbacks

Network polling defaults to five minutes, with fifteen-minute and manual alternatives. Claude requests are limited to at most one per five minutes even when repeatedly refreshed. Failed calls use increasing backoff; 403 and 429 observe cooldowns, including Retry-After. A rejected token is not retried until the saved token changes. No token refresh is attempted. Both providers refresh after wake. The dashboard and menu share one freshness rule; a past reset time also suppresses that window’s current percentage until a fresh reading arrives.

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

Set `QUOTABAR_BUILD_PATH` to keep build intermediates outside the source directory. The build script produces an ad-hoc signed personal app in `dist/`. For a stable launch-at-login installation, move the app into Applications before enabling that option. This local build is not notarized for distribution.

Tests also verify the helper release URL, manifest size/checksum validation, path-injection rejection, and strict official authorization-link handling. Tests cover the provider contracts, missing versus zero data, malformed values, grant counts and expiries, timestamp formats, account-matched caches, credential schema/expiry handling, read-only request construction, backoff, and exporter privacy. The test suite currently contains 23 Swift tests plus the exporter privacy test. Completing browser authorization and comparing both usage windows, reset times, and any reported reset grants against the provider account pages remain manual acceptance checks.

## Read-only scope

No reset-redemption route is implemented. QuotaBar does not send prompts, purchase credits, change subscription settings, or perform background token refresh. Only the user-triggered official Claude Code sign-in helper creates or updates its own credentials; the monitoring client does not write Keychain entries or modify Claude settings. It reads neither conversation logs nor Claude Desktop credential stores. There are no analytics or hosted backend. Quota snapshots remain in memory except for the separately enabled local status-line exporter.

References: [Codex App Server](https://learn.chatgpt.com/docs/app-server), [Claude credential management](https://code.claude.com/docs/en/authentication#credential-management), [Claude status-line usage fields](https://code.claude.com/docs/en/statusline#rate-limit-usage), [Claude reset offers](https://support.claude.com/en/articles/17007452-what-is-a-limit-reset). The internal OAuth usage/reset-grant contract comes from the user-supplied brief and is not presented as a documented public API.
