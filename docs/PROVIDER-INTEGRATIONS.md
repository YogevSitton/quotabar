# Provider integration details

Implementation notes for the current release. Read [AGENTS.md](../AGENTS.md) before changing these paths. Current verification remains compilation and static review only.

## Connect Codex

QuotaBar locates the Codex CLI bundled in ChatGPT/Codex or a standalone installation and reads `account/rateLimits/read` through its local app server. This reuses the existing ChatGPT subscription sign-in. It also checks common npm, nvm, Volta, Bun and pnpm global folders. API-key-only authentication does not provide subscription limits.

## Connect Claude

Claude automatically reuses the official CLI's saved subscription sign-in at startup and on refresh, just like Codex. There is no separate **Use existing sign-in** choice. **Connect Claude** checks the saved sign-in and, only if needed, starts the official browser sign-in directly, without a second native window or another sign-in button. If a helper is missing, this explicit action prepares the verified official helper, then checks the saved login before signing in. Progress, cancellation and errors appear in the popup; **Sign-in help…** opens the optional recovery window for reopening the official authorization page or entering a browser-provided code. To change accounts, sign in to a different account in Claude Code; QuotaBar follows its saved sign-in. Browser login runs only `auth login --claudeai`; finish authorization yourself. Startup, polling and retrying usage never start browser sign-in.

**QuotaBar no longer reads Keychain credentials or calls Claude's authenticated usage endpoint itself.** Claude Code manages its own normal saved sign-in. macOS may still require Claude Code itself to unlock or access its credentials; QuotaBar does not request that access or alter any Keychain permissions.

The usage reader starts a bounded Claude Code subprocess and sends only these control requests:

- `initialize`
- `get_binary_version`
- `get_usage` with `skip_behaviors: true`

When a usage read fails, a separate bounded `claude auth status` command checks the CLI’s reported authentication method and exit status. Only a confirmed signed-out or incompatible authentication method requests subscription sign-in. Unsupported status output, network/service failures, stale caches and version errors remain usage errors with a retry action. Raw status output stays in memory and is never displayed or logged.

It sends no user prompt, model turn, reset action, or authentication token. Tools, hooks, external MCP servers, project settings, customizations, telemetry, automatic updates, and session persistence are disabled for this reader. Managed policies remain effective. API keys and custom credential environments are not inherited. Do not use `--bare`: it disables subscription OAuth too. The CLI is responsible for its own credential handling; QuotaBar never refreshes or writes credentials itself. Background discovery never downloads a helper or starts browser sign-in.

This uses the experimental `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET` / `get_usage` interface that Anthropic added to its Agent SDK. The current reader requires CLI 2.1.309 or later because that is the locally inspected version with the skip-history behavior verified. Older or incompatible CLIs fail visibly. Claude usage still needs successful subscription authorization before live values can appear.

The result preserves five-hour/weekly usage, scheduled reset times, model windows, and extra usage whenever returned. The CLI is allowed to exit normally after a read so pending cache writes can finish before the sample timestamp is verified. Optional reset grants are parsed only if the CLI actually includes them. Missing grant inventory stays unknown and hidden; full reset-credit parity has not been verified through this route. Claude redemption continues to open the official Usage page for the user's own selection and confirmation.

Claude Code can answer from its own usage cache. QuotaBar reads only the non-secret account metadata and `cachedUsageUtilization` fields in `~/.claude.json`, matches the account and the returned quota windows, and preserves `fetchedAtMs`. It does not stamp an older CLI cache as newly fetched. A sample older than two minutes or one without verifiable provenance cannot supply current menu percentages. In-flight account changes invalidate the result. Transient usage failures retry automatically after one minute, increasing to at most five minutes; authentication/helper failures wait at least five minutes. Explicit connection verification can retry after sign-in.

Verification on 23 October 2026: the local official CLI 2.1.309 accepted initialization, the binary-version request, and `get_usage` with history scanning disabled. It reported zero model cost, zero model API duration, and empty model usage. It returned no eligible subscription windows for the helper's current sign-in, so actual live percentages, reset times, cache matching, and optional grants still need acceptance after browser authorization. Raw CLI output and account identifiers were not logged or saved. On 24 October, after the maintainer completed sign-in, 1.7.11 showed live five-hour/weekly readings and the reported weekly reset; observation times advanced across several automatic refresh cycles without clicking Retry. Optional Claude reset-grant fields remain unverified.

## Refresh and local fallbacks

Network polling is fixed at one minute, plus a read after wake. This is a client cadence, not a guaranteed provider-supported request quota. Successful Claude CLI usage queries are spaced at least one minute apart even when repeatedly refreshed. This sends up to 60 reads per provider per hour; no model inference requests are made. Claude reads have a dedicated timer at the exact next eligible read time, slightly beyond the CLI’s inspected 60-second cache TTL, so an early shared polling tick cannot skip a full minute. Transient failures use a one-to-five-minute backoff; the CLI owns its internal network throttling and authentication. QuotaBar does not receive or override raw HTTP Retry-After headers through this interface. Both providers refresh after wake. The dashboard and menu share one freshness rule; a past reset time also suppresses that window’s current percentage until a fresh reading arrives.

When Claude's live request is unavailable, the app selects the newest account-matched reading from:

1. The last successful usage response held in memory.
2. An optional Claude Code status-line snapshot.
3. `~/Library/Application Support/Claude/plan-usage-history.json` (version 2).

Disk history contributes percentages only: no reset times, credit counts, or expiries are inferred. Its original sample time is retained, even when it is hours old. Account/organization IDs are read from `~/.claude.json` only to keep readings from different accounts apart. A boolean unused-reset cache is not interpreted as a credit inventory because it cannot supply counts or expiry dates.

### Optional status-line exporter

`scripts/capture-claude-statusline.py` can receive Claude Code's status-line JSON and save only sanitized rate-limit fields, the active organization ID, and the capture time. It creates a private (0600) JSON snapshot at `~/Library/Application Support/QuotaBar/claude-statusline.json` using an atomic replacement. QuotaBar checks for changes every ten seconds and labels the saved reading Cached with its capture time. This requires an active Claude Code session to supply readings.

**The exporter is not installed or configured automatically.** Enabling it changes `~/.claude/settings.json` and requires your explicit consent. If you already use a status-line script, preserve or chain that script instead of replacing it. No Claude settings were changed during this implementation.


Additional/model windows and extra usage are parsed defensively but deliberately not displayed. Optional reset-credit fields are schema support, not verified live behavior.
