# Changelog

Notable changes to QuotaBar, for people using it. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/). While the version is `0.x`, a minor version may include breaking changes.

Add an entry under **Unreleased** in the same pull request as the change. Use the headings Added, Changed, Fixed, Removed and Security, and leave out empty ones.

## [Unreleased]

### Added

- Show or hide each installed provider from the More menu (**Show Codex**, **Show Claude**, **Show Antigravity**). A hidden provider leaves the menu bar and popup and is not polled; showing it again reads it on its usual schedule. Your choice is saved across restarts.
- Experimental Antigravity subscription usage, including separately reported Gemini 4 quota groups. Connect through the official CLI, choose the quota group shown in the menu bar, and see its remaining quota and reset times. Private CLI settings avoid the saved slash-command preference bug. A cancelled, timed-out or failed connection keeps its request cooldown, and Connect shows when another attempt is allowed. Live connection and quota behavior remain unverified.
- More > Logs... opens a private local diagnostic history with Copy logs and Clear logs controls. It keeps bounded provider outcomes, Claude cache-validation and retry details, Antigravity connection stages with the CLI's exit status and reply category, helper versions and update states across restarts, without credentials, account identifiers or raw replies.
- In-app updates under More > Updates..., with a default Stable channel and an opt-in Preview channel per Mac. Checks run about hourly and downloads are automatic by default; nothing installs until you click Install and Relaunch. Moving from published versions through 0.3.0 needs one manual download. Preview builds are published automatically from `main`.
- Release downloads include signed update metadata alongside the zip and its checksum.
- A blue countdown beside a menu bar percentage when that window resets automatically soon with usage still left, before the five-hour percentage and after the weekly one, such as `45m 80%/34%` or `80%/34% 9h`: the weekly window within 48 hours with any usage left, and the five-hour window in its last hour with at least 30% left. Unused usage does not carry over, so it suggests spending it first. It has no pill, so it stays distinct from manual reset chips. In the popup, that window shows **Use by** instead of **Auto reset**, and a **Use first** tag marks the provider whose leftover resets soonest.

### Changed

- **Quit QuotaBar** moved from the popup's power button into the More (ellipsis) menu. Command-Q still quits while the popup is open.
- Set the source version to 0.4.0 for the upcoming release.
- The menu bar item now fits its content, removing the empty space after each provider's usage, with a tighter 10-point gap between providers instead of 18 points. Ordinary percentage changes keep its width; reaching or leaving 100%, dropping below 10%, a countdown, `∞` or a reset chip appearing can change it, and such changes wait until the popup closes.
- Reduce healthy Claude polling to at least 2 minutes 10 seconds between reads. Validated readings remain current for less than four minutes to cover the next read, while failed refreshes immediately show saved values and wait five minutes, increasing to at most one hour after repeated failures. Codex keeps its one-minute interval.

### Removed

- Removed the menu bar hover tooltip. Hovering over the menu bar item no longer opens a tooltip window, avoiding a macOS bug where expanding items past the camera notch (using the `<<` button or an overflow manager) causes the hover panel to appear mid-screen. Reset countdowns and expiry details remain visible directly in the menu bar and popup, and VoiceOver keeps its full spoken summary.

### Fixed

- Clicking the menu bar item again closes the popup instead of briefly closing and reopening it.
- Keep Claude visible when QuotaBar's managed Claude Code helper is installed, even without Claude Desktop or a standalone CLI. Empty or incomplete helper installations do not count.
- Command-V, -C, -X, -A and -Z now work in text fields, such as the Antigravity and Claude authorization code fields. Previously only the context-menu Paste worked.
- Antigravity shows Gemini 4 Argon by default, listed first in the quota group menu, instead of asking you to choose a group.
- Antigravity no longer makes macOS ask "A keychain cannot be found to store "antigravity"" at sign-in and about every hour afterwards. QuotaBar's private Antigravity profile now points the official CLI at your own keychain folder, so it saves its sign-in in your login keychain, as it does when you run it yourself. QuotaBar still never reads it.
- Antigravity Connect and automatic checks no longer fail immediately. The official CLI rejected an option QuotaBar passed and exited before sign-in or reading quota, so every attempt failed and the wait before the next one grew.
- Antigravity no longer stops with "isolated settings could not be verified" after the official CLI's first full run. The CLI links one of QuotaBar's empty settings files to another, and QuotaBar now accepts that exact link while still refusing any other.
- Retain Claude's original usage failure message when Retry usage is clicked during a cooldown.
- Claude usage appears right after QuotaBar restarts or updates instead of showing `-/-` until the next scheduled check, up to 2 minutes 10 seconds later. When the last check succeeded, QuotaBar shows Claude Code's own saved sample for the same account while it is less than four minutes old; the plan name appears with the next check.
- Manual reset countdown tags and expiry warnings gradually blend from their existing yellow-orange color at 24 hours left to full red at 12 hours, instead of abruptly turning red at 24 hours.
- Detect Claude's expired-cache fallback as a failed refresh immediately, instead of accepting it until the sample reaches two minutes old. Keep the original values labeled **Saved reading** while waiting.
- Share and persist Claude's request deadline across QuotaBar copies for the same local user. Retry, restart, wake, sign-in verification and account changes no longer bypass the waiting period.

### Security

- Pin the maintainer's public verification key for signed updates. Builds made from source now check the public update feeds on the normal schedule and can link to a newer release, but never download or install it.

## [0.3.0] - 2026-10-27

### Added

- A small countdown chip after a provider's menu bar percentages when one of its reported manual resets expires within 3 days: orange with the days left, then red with the hours or minutes left in the last 24 hours. Room for the chip is always reserved, so the menu bar item no longer changes width when one appears.
- The menu bar tooltip shows each provider's next reset expiry with its countdown.

### Changed

- Tighten the menu bar spacing between the Codex usage and the Claude logo.
- Popup reset expiry warnings now start 3 days ahead in orange and turn red in the last 24 hours, instead of 24 hours and 1 hour.

### Fixed

- Show `∞` in the menu bar and **No 5-hour limit** in the popup for current Codex Pro readings without a five-hour limit. Keep missing, malformed and stale readings unavailable, including Claude's undocumented `five_hour: null`.

## [0.2.0] - 2026-10-26

### Added

- Show the app version at the bottom right of the popup.
- Subtle pace reference ticks on current usage meters, with even-use comparisons available on hover.
- Warnings for manual reset offers expiring within 24 hours, with stronger highlighting in the last hour and upcoming expiries shown before expired offers.

### Changed

- Remove the public preview label; documented limitations still apply.
- Make the downloaded-app installation a four-step Finder flow, with Terminal checksum verification and source builds in separate optional sections.
- Refresh public guidance with numbered download and source-build steps, first-launch and provider setup, troubleshooting, and privacy-reviewed light/dark UI examples rendered from synthetic data.

### Fixed

- Recheck Claude usage sooner when the official CLI receives a fresh account-matched sample during a failure backoff, instead of keeping the old error until the full retry delay expires.

## [0.1.0] - 2026-10-25

First public release.

### Added

- Menu bar summary of Codex and Claude five-hour and weekly usage, with reset countdowns when a window is exhausted.
- Popup with both providers side by side, scheduled reset times and reset-credit expiries.
- Ad-hoc signed app zip with a SHA-256 checksum. Not notarized; updates are manual.

[Unreleased]: https://github.com/YogevSitton/quotabar/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/YogevSitton/quotabar/releases/tag/v0.3.0
[0.2.0]: https://github.com/YogevSitton/quotabar/releases/tag/v0.2.0
[0.1.0]: https://github.com/YogevSitton/quotabar/releases/tag/v0.1.0
