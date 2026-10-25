# QuotaBar

A native macOS menu bar app for Codex (ChatGPT) and Claude subscription usage. See your remaining five-hour and weekly usage, scheduled reset times, and any reset credits and expiry dates the provider reports.

Independent community project, with no analytics or hosted backend. Not affiliated with or endorsed by OpenAI or Anthropic.

## Status

The first public preview is **0.1.0**. Earlier development builds used higher internal version numbers.

Requires an Apple Silicon Mac running macOS 14 or later. Codex and Claude live usage have been checked locally. Claude's usage interface is experimental; optional Claude reset credits and actual reset redemption remain unverified. Downloaded builds are ad-hoc signed and are not notarized by Apple. See [verification status](docs/VERIFICATION.md).

## Install

### Build from source

Install Xcode or a Swift 5.9+ toolchain, then:

```sh
git clone https://github.com/YogevSitton/quotabar.git
cd quotabar
./scripts/build.sh
open dist/QuotaBar.app
```

The app has no external Swift package dependencies. Move `QuotaBar.app` into Applications before enabling launch at login.

### Download a preview

If a packaged build is available, download its zip and matching `.sha256` file from [Releases](https://github.com/YogevSitton/quotabar/releases). In the download folder, verify the checksum using the actual version number:

```sh
shasum -a 256 -c QuotaBar-0.1.0.zip.sha256
```

Only continue if it prints `OK`. Extract the zip and move `QuotaBar.app` into Applications. The checksum detects corruption; it is not a substitute for Developer ID signing or notarization. macOS may block a downloaded preview. See [Apple's guidance on opening apps from unidentified developers](https://support.apple.com/en-us/102445) before deciding whether to allow it.

Updates are manual: quit QuotaBar, download or build the new version, and replace the app. There is no in-app updater in this release.

## Usage

Each connected provider has its transparent logo followed by `5h%/weekly%`, such as `93%/91%`. These are **remaining** percentages. When five-hour usage is exhausted, its reset countdown replaces the percentage, such as `2h13m/45%`. When the weekly window is exhausted, only its weekly countdown appears. Percentages gradually turn red between 50% and 10% remaining; countdowns stay uncolored. A dash means a current value is unavailable.

Click the menu bar item to open the compact popup. Installed providers appear side by side with their five-hour and weekly meters, automatic reset times and reported reset credits. Reset and expiry times include a countdown on the same line; the timezone is in the tooltip. The popup does not scroll. Longer inventories, descriptions, saved readings and recovery information open in a separate resizable Details window through contextual links. Additional/model limits and extra usage are intentionally not displayed.

The header contains **Quit** (power) and **More** (ellipsis). More contains **Launch at login**. Refresh runs automatically every minute and after wake; there is no manual refresh control or Settings window. You can Command-drag the menu bar item to reposition it. Changing percentages does not change its width.

Screenshots are omitted until current, privacy-reviewed captures are available.

## Connect your providers

**Codex:** Install the Codex CLI or the ChatGPT/Codex desktop app and sign in there with your ChatGPT subscription. QuotaBar detects the bundled CLI and common standalone install locations, including npm, nvm, Volta, Bun and pnpm. It reuses the CLI's existing sign-in through its local app server. API-key-only authentication does not provide subscription usage.

**Claude:** Install Claude Desktop or a standalone Claude Code CLI. The usage reader requires Claude Code 2.1.309 or later. QuotaBar automatically checks its saved subscription sign-in. If needed, **Connect Claude** prepares a verified official helper and starts the official browser sign-in after checking the existing login. Progress, cancel and errors stay in the popup; optional **Sign-in help** opens a separate recovery window. Finish browser authorization yourself. To change accounts, sign in to the other account in Claude Code; QuotaBar follows it.

Startup, polling and retrying usage never start browser sign-in or download a helper. Missing usage is not treated as proof that you are signed out. Network, version, service and stale-cache errors offer retry. Providers with no detected local installation are hidden and are not polled.

The external Usage buttons open [ChatGPT usage settings](https://chatgpt.com/settings/usage) and [Claude usage settings](https://claude.ai/settings/usage).

## Freshness and privacy

Monitoring sends read-only control requests through the official CLIs, with no user/model prompts or inference requests. QuotaBar does not purchase credits, change subscriptions, refresh tokens, or read/write credential stores. The official CLIs manage their own authentication. QuotaBar does not read conversation logs, scrape browser credentials, alter Keychain access, or configure Claude settings.

Claude reads use only `initialize`, `get_binary_version` and `get_usage`, always with `skip_behaviors: true`. The reader disables project settings, tools, hooks, external MCP servers, telemetry, automatic updates and session persistence. A bounded `claude auth status` check can classify a failure using its authentication method and exit status; raw replies are not logged.

Claude Code may return a cached reading. QuotaBar matches non-secret account/cache metadata in `~/.claude.json` and preserves its original `fetchedAtMs`. Missing provenance or a sample older than two minutes cannot supply current percentages. Expired quota windows require a fresh reading. Missing or malformed values stay unknown.

Transient Claude failures retry automatically with a one-to-five-minute backoff. The newest account-matched reading remains clearly labeled **Saved reading**, with its original timestamp; it never supplies current menu percentages. Optional status-line snapshots and local Claude usage history supply historical percentages only. See [provider integration details](docs/PROVIDER-INTEGRATIONS.md).

There is no hosted backend or analytics. Quota snapshots stay in memory except for the separately enabled local status-line exporter. A confirmed Codex reset stores local recovery metadata, never credentials.

### Optional status-line exporter

`scripts/capture-claude-statusline.py` saves only sanitized usage fields, the organization ID used to match accounts, and the capture time. The atomic snapshot is private (0600) at `~/Library/Application Support/QuotaBar/claude-statusline.json`. It requires an active Claude Code session and is labeled historical.

The exporter is never installed automatically. Configuring it changes `~/.claude/settings.json` and requires your explicit consent. Preserve or chain any existing status-line script.

## Use a saved reset

**Codex:** A supported live credit has **Use reset**. A fresh account-verified reading and a separate confirmation are required. Cancel is the default. Only **Use 1 reset** sends the request, targeting the selected account and credit. QuotaBar checks them again and persists the UUID idempotency key before sending. It never buys or automatically selects another reset.

An uncertain result blocks new requests. **Review saved reset request** requires a new confirmation and reuses only the original account, credit and key. Restarting never replays it. An unreadable recovery record disables redemption. The private recovery record is `~/Library/Application Support/QuotaBar/pending-codex-reset.json` (directory 0700, file 0600). Stale readings, expired credits and unsupported reset types cannot start a reset. Count-only and unsupported inventories use the official Usage page.

**Claude:** **Use a reset on Claude** opens the official Usage page for your own selection and confirmation. QuotaBar does not implement an undocumented Claude reset request.

**Actual reset redemption has not been verified. No reset action or confirmation was exercised and no reset credit was spent during development verification.** Optional Claude reset-credit fields are undocumented and have not been verified against a live account.

## Limitations

- Claude support depends on an experimental control interface and may break after CLI changes.
- Missing provider fields remain unknown; full reset-credit parity is not promised.
- Account connection reliability has not been validated across a broad range of accounts and installations.
- Builds have been checked only on Apple Silicon. Intel support is unverified.
- Packaged previews are ad-hoc signed, not notarized. Developer ID signing, notarization and a supported update channel remain future work.

## Development

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md). Current verification is compilation and static review only. Never exercise resets, send live reset requests or consume credits during development. CI compiles the app and test targets without executing tests.

```sh
./scripts/build.sh
swift build --build-tests --disable-sandbox
python3 scripts/audit-public-tree.py --public-docs
codesign --verify --deep --strict dist/QuotaBar.app
```

Set `QUOTABAR_BUILD_PATH` to put build intermediates elsewhere. `scripts/package-release.sh` creates a zip and SHA-256 checksum and verifies the extracted app's signature; it uploads nothing. Normal builds use committed artwork. `scripts/build-icon.sh` explicitly regenerates artwork and strips metadata. [Assets/ICON.md](Assets/ICON.md) records its provenance.

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/YogevSitton/quotabar/security/advisories/new), following [SECURITY.md](SECURITY.md). Use redacted or synthetic examples in issues.

## License and trademarks

QuotaBar's own code, documentation and original artwork are under the [MIT License](LICENSE), copyright 2026 Yogev Sitton.

OpenAI, ChatGPT and Codex names and marks belong to OpenAI; Anthropic and Claude names and marks belong to Anthropic. Provider names and artwork are excluded from the MIT grant and identify their respective integrations. QuotaBar is not affiliated with, endorsed by or sponsored by either provider.
