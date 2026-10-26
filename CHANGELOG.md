# Changelog

Notable changes to QuotaBar, for people using it. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/). While the version is `0.x`, releases are public previews and a minor version may include breaking changes.

Add an entry under **Unreleased** in the same pull request as the change. Use the headings Added, Changed, Fixed, Removed and Security, and leave out empty ones.

## [Unreleased]

### Added

- Subtle pace reference ticks on current usage meters, with even-use comparisons available on hover.
- Warnings for manual reset offers expiring within 24 hours, with stronger highlighting in the last hour and upcoming expiries shown before expired offers.

### Changed

- Refresh public guidance with numbered download and source-build steps, first-launch and provider setup, troubleshooting, and privacy-reviewed light/dark UI examples rendered from synthetic data.

## [0.1.0] - 2026-10-25

First public preview.

### Added

- Menu bar summary of Codex and Claude five-hour and weekly usage, with reset countdowns when a window is exhausted.
- Popup with both providers side by side, scheduled reset times and reset-credit expiries.
- Ad-hoc signed app zip with a SHA-256 checksum. Not notarized; updates are manual.

[Unreleased]: https://github.com/YogevSitton/quotabar/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/YogevSitton/quotabar/releases/tag/v0.1.0
