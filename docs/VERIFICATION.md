# Verification status

This file records what has been checked against live provider accounts, what has only been compiled or tested with synthetic fixtures, and what remains unverified. It is the place for dated verification notes; keep the README focused on behavior.

## Verified against live accounts

- **Codex live usage.** Five-hour and weekly usage read through the Codex app server have been checked locally.
- **Claude browser sign-in launch.** The explicit Connect Claude action starts the official `auth login --claudeai` flow.
- **Claude read-only control protocol (23 October 2026).** The local official Claude CLI 2.1.309 accepted `initialize`, `get_binary_version` and `get_usage` with history scanning disabled. It reported zero model cost, zero model API duration and empty model usage. It returned no eligible subscription windows for the helper's sign-in at the time. Raw CLI output and account identifiers were not logged or saved.
- **Claude live usage (24 October 2026).** After the maintainer completed sign-in, QuotaBar 1.7.11 showed live five-hour/weekly readings and the reported weekly reset, and observation times advanced across several automatic refresh cycles without clicking Retry.
- **Layout.** Both provider cards and reset expiry countdowns were visually checked, with no popup scrolling.
- **Pace presentation (25 October 2026).** During local development, the final popup was visually checked with both providers: pace appears only as a meter tick, with no separate warning row. This observation predates migration of the feature onto the public repository's history; the migrated sources and meter tooltip are validated by compilation and static review.
- **Usage links.** The ChatGPT and Claude Usage destinations were checked in a signed-in browser.

## Compiled or tested with fixtures only

- The Swift test suite (synthetic fixtures) covers provider contracts, missing versus zero data, malformed values, grant counts and expiries, timestamp formats, account-matched caches, CLI response parsing, missing subscription data, backoff, the helper release URL, manifest size/checksum validation, path-injection rejection and strict authorization-link handling. The current release compiles these targets without executing them, locally and in CI. An earlier abandoned preparation branch reported fixture tests; that is not a test result for this release.
- The exporter and audit have synthetic Python tests, not executed during this release preparation. The tree and history audits themselves run offline.
- **Pace and reset-expiry indicators.** Synthetic cases cover both window lengths, pace tolerance, invalid or expired dates, the near-zero weekly reference before reset, expiry warning boundaries, unknown expiries, and ordering upcoming offers ahead of expired ones. These cases are compiled without execution. No provider, credential, reset redemption, or recovery request is involved.
- **Codex reset redemption.** The confirmation, specific-credit targeting, idempotency key persistence and recovery record were compiled and statically reviewed only. No reset button, confirmation, mutation request, recovery retry or reset test has been exercised, and no reset credit has been consumed.
- **Claude reset hand-off.** Opening Claude's Usage page is implemented; no Claude reset has been performed through it.
- **Updates and releases (26 October 2026).** The build identity, signed update metadata, Stable and Preview channel selection, schedule and backoff, Updates window, `QuotaUpdater` helper, release workflow and its static trust checks were compiled and statically reviewed. Synthetic cases cover metadata parsing and signatures, downgrade and conflicting-identity rejection, absent and invalid feeds, and backoff; they compile without being executed. Local packaging produced a source-mode build whose app and helper signatures verify. No release key, secret, variable, environment or Pages site exists, the release workflow has never run, and no update has been downloaded, installed, denied, rolled back or recovered. See [Releases and in-app updates](UPDATES.md).

## Not yet verified

- Claude's optional reset-grant fields (counts and expiries) through `get_usage`, end to end against a live account.
- Reset-expiry warning appearance against actual reported offers within the last 24 hours or last hour of expiry.
- Comparing both usage windows, reset times and any reported reset grants against the provider account pages after a fresh sign-in.
- Actual reset redemption behavior for either provider.
- Developer ID signing and notarization.
- Publishing: Preview publication from an eligible `main` build after activation, the first Stable promotion becoming GitHub Latest, feed deployment, and free standard-runner usage.
- Update qualification on isolated Macs or accounts without provider CLIs: manual migration from 0.1.0; check, download, install and relaunch; App Management denial and approval; launch at login across an update; Gatekeeper behavior; interrupted replacement and recovery; channel switching; and missing-feed behavior.
- Builds and behavior on Intel Macs.

## Rules for updating this file

- Never claim live verification that did not happen; state the version, date and what was observed.
- Never exercise reset actions or spend reset credits to verify anything here. See `AGENTS.md`.
- Record update qualification only from separately authorized runs, with the build number, macOS version, steps and what was observed. Compilation is not evidence of installation.
- Do not record raw CLI output, account identifiers, emails or tokens.
