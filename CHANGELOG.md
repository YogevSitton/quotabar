# Changelog

Notable changes to QuotaBar, for people using it. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/). While the version is `0.x`, a minor version may include breaking changes.

Add an entry under **Unreleased** in the same pull request as the change. Use the headings Added, Changed, Fixed, Removed and Security, and leave out empty ones.

## [Unreleased]

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

[Unreleased]: https://github.com/YogevSitton/quotabar/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/YogevSitton/quotabar/releases/tag/v0.2.0
[0.1.0]: https://github.com/YogevSitton/quotabar/releases/tag/v0.1.0
