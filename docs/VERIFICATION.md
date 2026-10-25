# Verification status

This file records what has been checked against live provider accounts, what has only been compiled or tested with synthetic fixtures, and what remains unverified. It is the place for dated verification notes; keep the README focused on behavior.

## Verified against live accounts

- **Codex live usage.** Five-hour and weekly usage read through the Codex app server have been checked locally.
- **Claude browser sign-in launch.** The explicit Connect Claude action starts the official `auth login --claudeai` flow.
- **Claude read-only control protocol (23 October 2026).** The local official Claude CLI 2.1.309 accepted `initialize`, `get_binary_version` and `get_usage` with history scanning disabled. It reported zero model cost, zero model API duration and empty model usage. It returned no eligible subscription windows for the helper's sign-in at the time. Raw CLI output and account identifiers were not logged or saved.
- **Claude live usage (24 October 2026).** After the maintainer completed sign-in, QuotaBar 1.7.11 showed live five-hour/weekly readings and the reported weekly reset, and observation times advanced across several automatic refresh cycles without clicking Retry.
- **Layout.** Both provider cards and reset expiry countdowns were visually checked, with no popup scrolling.
- **Usage links.** The ChatGPT and Claude Usage destinations were checked in a signed-in browser.

## Compiled or tested with fixtures only

- The Swift test suite (synthetic fixtures) covers provider contracts, missing versus zero data, malformed values, grant counts and expiries, timestamp formats, account-matched caches, CLI response parsing, missing subscription data, backoff, the helper release URL, manifest size/checksum validation, path-injection rejection and strict authorization-link handling. The current release compiles these targets without executing them, locally and in CI. An earlier abandoned preparation branch reported fixture tests; that is not a test result for this release.
- The exporter and audit have synthetic Python tests, not executed during this release preparation. The tree and history audits themselves run offline.
- **Codex reset redemption.** The confirmation, specific-credit targeting, idempotency key persistence and recovery record were compiled and statically reviewed only. No reset button, confirmation, mutation request, recovery retry or reset test has been exercised, and no reset credit has been consumed.
- **Claude reset hand-off.** Opening Claude's Usage page is implemented; no Claude reset has been performed through it.

## Not yet verified

- Claude's optional reset-grant fields (counts and expiries) through `get_usage`, end to end against a live account.
- Comparing both usage windows, reset times and any reported reset grants against the provider account pages after a fresh sign-in.
- Actual reset redemption behavior for either provider.
- Developer ID signing and notarization, and an in-app update path.
- Builds and behavior on Intel Macs.

## Rules for updating this file

- Never claim live verification that did not happen; state the version, date and what was observed.
- Never exercise reset actions or spend reset credits to verify anything here. See `AGENTS.md`.
- Do not record raw CLI output, account identifiers, emails or tokens.
