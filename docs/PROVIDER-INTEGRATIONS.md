# Provider integration findings — 23 October 2026

## Codex

The app uses the installed Codex CLI's local app-server protocol, sending `initialize` and `account/rateLimits/read`. Codex owns authentication. The separately confirmed reset operation is unrelated to polling and was not exercised during this investigation.

## Claude: a CLI-owned route exists

Anthropic added `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()` to its Agent SDK in [v0.3.169](https://github.com/anthropics/claude-agent-sdk-typescript/releases/tag/v0.3.169). The corresponding CLI control request is `get_usage`. This corrects the earlier conclusion based only on the general CLI reference and status-line documentation.

The locally available official Claude Code 2.1.309 binary was inspected. Its usage request supports `skip_behaviors: true`, expressly skipping the scan of local transcripts. Its handler returns subscription type, account quota windows, optional model limits, and extra usage without a model turn. Its data can also come from Claude Code's account-matched cached usage snapshot.

A bounded local probe sent only initialize/get_usage and a separate initialize/get_binary_version check. It used an empty trusted directory, no tools/hooks/MCP servers, no project settings or customizations, and no session persistence. Results:

- Control initialization succeeded.
- CLI version was 2.1.309.
- The usage control request succeeded, with history-derived behaviors absent.
- Model cost and model API duration were zero; model usage was empty.
- `rate_limits_available` was false and quota windows were absent for the helper's current sign-in.

This verifies the protocol and its no-model-call behavior, not successful subscription authorization or actual quota values. Browser login must still be completed by the human. No credential values or raw CLI replies were displayed, saved, or committed. No reset controls, mutations, or reset tests were exercised.

QuotaBar 1.7.0 now uses this route. Direct Keychain queries, access-token parsing, and direct authenticated Claude HTTP request construction were removed. The existing sign-in helper still runs official `auth login --claudeai`; the CLI handles its own normal authentication. QuotaBar sends only an allowlisted set of control requests and rejects requests to authorize other actions. The current minimum version is conservatively 2.1.309, whose skip-history behavior was inspected locally.

The reader verifies the CLI response against the same account's non-secret `cachedUsageUtilization` snapshot and preserves its original `fetchedAtMs`. Old, mismatched, or unverifiable samples cannot become freshly fetched/current menu values. Actual timestamp matching after successful subscription login is still unverified locally.

Optional reset-grant inventory is preserved only if returned; its availability through the experimental CLI response has not been established. Missing inventory stays unknown. Claude reset redemption continues to hand off to the official Usage page. This is not a complete verification of all Claude plan/reset fields.

## Gemini / Antigravity: documented read-only CLI support

Google's [CLI changelog](https://www.antigravity.google/changelog?tab=cli) says release 1.1.7 added direct print-mode answers for `/usage`, `/quota`, and `/credits`, including structured JSON, without an agent turn, quota spending, or conversation creation. Current [headless documentation](https://antigravity.google/docs/cli/headless/) explicitly distinguishes CLI-handled `/usage` from model prompts and says these commands must run as separate print invocations, not messages in a streaming conversation.

The candidate invocation is:

```sh
agy -p "/usage" --output-format json
```

Use a recent official CLI with the documented direct-command behavior. Older versions could interpret slash commands as model prompts; do not use an unknown version as a polling fallback, and never use `--disable-slash-commands` for a quota reader. Parsing must fail closed if the expected read-only response is absent.

The documented [status-line payload](https://antigravity.google/docs/cli/statusline/) also provides quota buckets with `remaining_fraction` or `remaining_amount`, `reset_time`, and `reset_in_seconds`. It is another CLI-owned source, but depends on an active session. [Authentication documentation](https://antigravity.google/docs/install/) confirms the standalone CLI can sign in through the browser; installing the full IDE is unnecessary. Google directs consumer Gemini CLI/Code Assist accounts to Antigravity in its [migration notice](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals).

Neither Antigravity nor Gemini CLI was found in the checked standard app/executable paths on this Mac. No installation, Google sign-in, account query, or model request was performed. The exact JSON shape, account matching, sample freshness, five-hour/weekly bucket mappings, credit balance, and any credit expiry still need local verification after CLI installation and sign-in. `/credits` describes AI credits; it is not evidence of redeemable usage-reset credits.

This establishes a documented route for Google's **coding quotas**. It does not establish access to the Gemini consumer chat application's limits or Gemini API project quotas, and Gemini is not yet implemented in QuotaBar.

## Saved sign-in behavior (1.7.7)

Both providers automatically reuse their official CLI’s saved subscription sign-in. Claude’s connection window now checks the saved login immediately; the separate “Use existing sign-in” action was removed. A missing helper can be prepared explicitly, then the saved login is checked before offering browser login. Switch-account remains an explicit optional action.

Claude usage failures are not authentication evidence. A bounded, read-only `claude auth status` subprocess may classify a failed read: documented exit 1 plus `authMethod: none` means signed out, exit 0 plus `claude.ai` means saved subscription authentication, and known alternate methods require subscription authentication for these quotas. Unknown/malformed output is not treated as signed out. See [Anthropic’s CLI reference](https://code.claude.com/docs/en/cli-reference). Raw replies, account fields and credentials are never logged or persisted. Current CLI live usage still requires end-to-end acceptance; this change does not claim to verify the subscription or reset inventory.

The 1.7.7 app and existing test targets compiled successfully; no tests or reset controls were executed. Opening the updated connection window automatically checked the saved login and the local official CLI reported signed out in the default profile. The window showed one Sign in with Claude action, with no Use existing sign-in choice. Browser authorization was not started during verification.
