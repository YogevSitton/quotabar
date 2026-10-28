# Changelog

Notable changes to QuotaBar, for people using it. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/). While the version is `0.x`, a minor version may include breaking changes.

Add an entry under **Unreleased** in the same pull request as the change. Use the headings Added, Changed, Fixed, Removed and Security, and leave out empty ones.

## [Unreleased]

### Added

- In-app updates under More > Updates..., with a default Stable channel and an opt-in Preview channel per Mac. Checks run about hourly and downloads are automatic by default; nothing installs until you click Install and Relaunch. Moving from published versions through 0.3.0 needs one manual download. Publishing these channels is not switched on yet.
- Release downloads include signed update metadata alongside the zip and its checksum.

### Changed

- The menu bar item now fits its content, removing the empty space after each provider's usage, and providers are separated by the same space as neighboring menu bar icons. Ordinary percentage changes keep its width; reaching or leaving 100%, dropping below 10%, a countdown, `∞` or a reset chip appearing can change it, and such changes wait until the popup closes.
- Reduce healthy Claude polling to at least 90.5 seconds between reads. Failed refreshes wait five minutes, increasing to at most one hour after repeated failures. Codex keeps its one-minute interval, and Claude's two-minute freshness limit is unchanged.

### Fixed

- Detect Claude's expired-cache fallback as a failed refresh immediately, instead of accepting it until the sample reaches two minutes old. Keep the original values labeled **Saved reading** while waiting.
- Share and persist Claude's request deadline across QuotaBar copies for the same local user. Retry, restart, wake, sign-in verification and account changes no longer bypass the waiting period.

### Security

- Pin the maintainer's public verification key for future signed updates. Publishing remains disabled pending activation and installation qualification.

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
