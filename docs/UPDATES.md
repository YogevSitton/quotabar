# Releases and in-app updates

This is the canonical policy and runbook for QuotaBar's releases, update channels and in-app updater. Other documents summarize it and link here.

## Current state

- **Shipped:** v0.1.0, v0.2.0 and v0.3.0, with v0.3.0 the latest Stable release. These releases predate the updater; moving to an updater-enabled release is one manual download. Existing downloads and release tags stay as published.
- **Preview publishing enabled (28 October 2026):** the public verification key is committed, the `release-signing` and `stable-approval` environments are configured, and GitHub Pages uses GitHub Actions with HTTPS enforced. `QUOTABAR_PREVIEW_SINCE` is `a12f999b5610fc3e7750d259f7640b9c81c6f563` and `QUOTABAR_PUBLISHING` is `enabled`. Only eligible merges after that boundary publish; the first signed Preview is pending. The signing secret's presence was checked by name only, so matching it to the public key remains unverified. Stable promotion has not been performed.
- **Not yet qualified:** installation, permission prompts, relaunch, recovery and multi-Mac behavior have not been tried on a real Mac. See [Verification status](VERIFICATION.md). Compiling the code is not evidence that an update installs.

## One public repository

Source, pull requests, issues and every download live in the public [YogevSitton/quotabar](https://github.com/YogevSitton/quotabar) repository. There is no private development mirror and no separate downloads repository. Receiving Macs need no source checkout, Xcode, GitHub account, token or GitHub command-line tool.

## Channels

| | Stable | Preview |
| --- | --- | --- |
| Default on a Mac | Yes | No; opt in on each Mac in the Updates window |
| What it contains | A build the maintainer explicitly promotes | Eligible successful builds of changes merged into `main` |
| Who can download it | Everyone (public) | Everyone (public) |
| GitHub release | Full release, marked Latest | Prerelease, never Latest |
| Tag | `v<version>`, such as `v0.2.0` | `preview-<build>`, such as `preview-41` |

Stable is a curated update channel, not a claim of 1.0 maturity. Stable releases do not carry a preview label; Preview builds are explicitly labeled prereleases.

**Preview eligibility.** A `main` revision is published to Preview only when all of these hold:

1. The CI workflow ran for a push to `main` in this repository and succeeded, and publication uses that exact commit.
2. The commit was merged after the owner's activation boundary (`QUOTABAR_PREVIEW_SINCE`, below).
3. Its build number is higher than the newest published Preview.

Pull requests, forks and other branches never publish. A failed or unverified build never advances either channel.

**Latest wins.** Publications run one at a time. When several merges land quickly, a newer pending publication replaces an older pending one, so not every intermediate commit gets its own Preview build.

**Stable promotion** reuses the exact bytes of an already published, verified Preview. Nothing is rebuilt; only the release tag, the asset name and the signed metadata change. A merge, a version bump or a Preview publication never promotes Stable on its own.

## Installing for the first time, and moving from releases through 0.3.0

1. Open the repository's [Releases](https://github.com/YogevSitton/quotabar/releases).
   - For Stable, use the release marked **Latest**. Currently that is the pre-updater v0.3.0 release. To get the updater, wait for the first updater-enabled Stable release or deliberately choose Preview.
   - For Preview, use the newest `preview-<build>` prerelease.
2. Download the zip and extract it in Finder. For optional Terminal checksum verification, also download its `.sha256` and run `shasum -a 256 -c <zip name>.sha256` in the download folder; if you perform this check, continue only if it prints `OK`.
3. Quit any running QuotaBar, extract the zip, and move `QuotaBar.app` into `/Applications` (or `~/Applications`), replacing the old copy.
4. Open it. macOS will likely block this first ad-hoc signed download. If you decide to allow it, use **System Settings > Privacy & Security > Open Anyway**. See [Apple's guidance](https://support.apple.com/en-us/102445).

The checksum detects corruption. It is not a substitute for Developer ID signing or notarization, which QuotaBar does not have.

## Using the updater

- **More > Updates...** opens a separate, resizable Updates window. The compact popup is unchanged, and there is no Settings window.
- **Channel:** Stable by default. Choose Preview on each Mac that should follow `main`.
- **Automatic checks and downloads** are both on by default and can be turned off. The first check runs 2-10 minutes after launch, then about hourly (plus or minus five minutes) while QuotaBar runs, and after waking from sleep when the last check is more than an hour old. **Check for Updates** checks immediately.
- **Installing always needs your click.** When a newer build has been downloaded and verified, the window shows its version, build and channel, with **Install and Relaunch**. Only that click installs that exact build.
  - Quitting, restarting, waking, switching channels, granting a permission or reading saved state never installs anything.
  - There is no install-on-quit.
- **No downgrades.** Switching from a newer Preview to Stable keeps the installed build. Stable updates resume once a Stable build newer than it is published.
- **Builds made from source** (`./scripts/build.sh`) are marked as source builds. Once the public key is committed, they can show that a release is available, with a link to Releases, but they never download or install updates. Until then they show that the build has no update key.
- **Location:** installing requires the app at exactly `/Applications/QuotaBar.app` or `~/Applications/QuotaBar.app`, owned by you. A copy run from Downloads or another folder shows how to move it.

## Network access and privacy

Update checks download public files anonymously over HTTPS:

- the signed channel feeds `https://yogevsitton.github.io/quotabar/updates/v1/stable.json` and `preview.json` on GitHub Pages;
- release archives from `https://github.com/YogevSitton/quotabar/releases/download/...`, which may redirect to GitHub's asset hosts.

No account, token, cookie, credential or GitHub command-line tool is used, and none will ever be requested.

| Answer | Meaning | What QuotaBar does |
| --- | --- | --- |
| 404 or a feed that does not exist | Nothing is published for that channel yet | Shows that; checks again on the normal schedule |
| Rate limit (429, or 403 with rate-limit headers) | GitHub asked clients to wait | Waits as long as GitHub asks, from one minute up to 24 hours, for every check and download, including manual ones |
| Timeout, connection error or 5xx | Temporary problem | Retries after 5, 15, 30, then 60 minutes |
| Malformed, oversized or unverifiable data | Not trustworthy | Ignores and reports that feed; never installs it |

These rules apply to feed checks and release downloads alike, and the 5, 15, 30, 60-minute progression continues until a check and any needed download both succeed. In every case the installed app is left as it is. If one feed is invalid, a valid, independently signed feed can still offer an update on Preview.

QuotaBar sends no analytics, and its update checks carry no account or usage data. GitHub sees ordinary HTTPS requests from your IP address.

## Integrity

- Every release has `QuotaBar-update.json`: signed metadata naming the repository, channel, build, version, commit, archive name, size and SHA-256, minimum macOS, architecture, identifiers and public key.
- It is signed with an Ed25519 key that only the release workflow's signing step can use. The app pins the public key it was built with and rejects metadata that is unsigned, signed by another key, malformed, for another app, architecture or channel, or older than what is installed.
- A build number that appears again with different contents is refused.
- The downloaded archive must match the signed size and hash. Its ZIP structure is inspected before extraction: one `QuotaBar.app`, no links, no special files, no path tricks. The extracted app and its helper must carry the expected identity and a valid code signature.
- A separate `.sha256` file is published with every archive for manual checks.

## macOS permissions and recovery

QuotaBar is ad-hoc signed and not notarized, because that needs a paid Apple Developer membership. Be aware:

- **First approval:** your first manual download is quarantined by your browser, and macOS will likely require Open Anyway once.
- **Updates are not quarantined.** QuotaBar does not mark the update it downloads and verifies itself as quarantined, so macOS's first-launch download check does not run for it again. That protection comes from the signature check above, plus your click. QuotaBar never removes quarantine from any file, never changes Gatekeeper settings or file permissions (ACLs), and never asks for Full Disk Access.
- **App Management:** replacing an app in Applications is protected by macOS. macOS may block the replacement or ask you to allow QuotaBar under **System Settings > Privacy & Security > App Management**. Because each ad-hoc build has a different code identity, the prompt may come back on later updates. QuotaBar does not promise prompt-free updates.
- **Launch at login:** your setting is left as it is. After an update, the More menu shows the actual state; it is not re-registered behind your back. Whether macOS keeps it across an ad-hoc replacement is still to be qualified.

### How an install works

1. Your click creates a private transaction folder under `~/Library/Application Support/QuotaBar/Updates/Jobs/` with the verified archive, its metadata and a copy of the bundled helper (`QuotaUpdater.app`).
2. The helper checks that it was started by this running QuotaBar for this exact request, which can only be used once. It re-verifies everything, then waits for QuotaBar to quit.
3. The first change it makes is to move the intact installed app into the transaction folder as `Previous.quotabar-backup`. If macOS refuses this step, nothing has changed. QuotaBar reopens and explains how to allow it, and you click Install again. Nothing retries automatically.
4. The verified new app is moved into place and opened. When it starts, it confirms the transaction.

### Outcomes

| Updates window shows | What happened | What remains |
| --- | --- | --- |
| Updated from build N | The new build started and confirmed | `Previous.quotabar-backup` kept for manual rollback |
| macOS did not allow QuotaBar to replace itself | Permission denied at the first step | Nothing changed |
| The last update did not start | Refused or cancelled before any change | Nothing changed |
| Build N could not be started, so build M was restored | The new build failed to open, and the previous app was put back | The failed copy is kept |
| An earlier update did not confirm that it finished | The new build was put in place but never confirmed | Both copies kept; see below |

**Remove recovery copies** in the Updates window deletes only settled transactions: completed ones whose backup is older than the running build, and ones that left or restored the running build. It never deletes an uncertain or unknown transaction, and nothing is deleted automatically.

**Manual recovery** after an uncertain result:

1. Quit QuotaBar.
2. Open the transaction folder with **Show in Finder**.
3. If `/Applications/QuotaBar.app` is missing or will not open, rename `Previous.quotabar-backup` to `QuotaBar.app` and move it into Applications.
4. Delete the transaction folder only after the app you want is in place and opens. Recovery copies take some disk space, roughly the size of the app.

## Versions, build numbers, tags and assets

- [`release-version.json`](../release-version.json) is the only place versions are set.
  - `displayVersion` is the user-facing version (public 0.x sequence, Semantic Versioning).
  - `anchorCommit` and `anchorBuild` pin build numbering to public history.
  - `publicKey` is the update verification key.
  - Do not hard-code versions in scripts.
- **Build number** = `anchorBuild` (28) + the number of first-parent commits from `anchorCommit` (`c05d491`, the commit released as v0.1.0 build 28) to the built commit. `main` is squash-only with linear history and no force-pushes, so the number only increases. Build numbers are independent of the display version, and earlier internal development versions have no bearing on them.
- [`scripts/build-identity.sh`](../scripts/build-identity.sh) computes this.
  - Source builds never fail: without the anchor or full history, they use build 0.
  - Release builds (`QUOTABAR_RELEASE_BUILD=1`, set only by the release workflow) fail unless history is complete, the anchor is on `main`'s first-parent line, the worktree is clean, the build is above 28 and the public key is committed.
- **Tags and assets:**
  - Preview: `preview-<build>` with `QuotaBar-preview-<build>.zip`.
  - Stable: `v<version>` with `QuotaBar-<version>.zip`, the same bytes as the promoted Preview.
  - Each also has the `.sha256` and `QuotaBar-update.json`.
  - Contributor and CI packaging writes `dist/QuotaBar-<version>.zip`.
- **Never moved.** Published tags, releases and assets are never moved, replaced or deleted. A broken build is fixed by a newer build, and a display version is promoted to Stable only once. The historical v0.1.0, v0.2.0 and v0.3.0 releases stay as published. The first updater-enabled Stable promotion replaces the existing GitHub Latest selection; it does not alter old releases.

## Contributor packaging versus trusted publishing

- Contributors and pull-request CI build and package without any secret: `./scripts/build.sh` and `./scripts/package-release.sh`. Packaging creates the zip and checksum, extracts the zip and verifies its signature and checksum, and uploads nothing.
- CI has read-only permissions and no secrets. [`scripts/check-workflow-trust.py`](../scripts/check-workflow-trust.py) fails if a pull-request workflow references secrets or write access, or if the release workflow breaks its trust rules.
- Only [`.github/workflows/release.yml`](../.github/workflows/release.yml) builds in release mode and signs. It runs only after a successful CI push run on `main` (Preview) or an owner dispatch on `main` (Stable). Pull-request and fork code never reaches it.
  - The build and packaging job has no secrets.
  - Signing happens in a separate job, in one step that receives `QUOTABAR_UPDATE_SIGNING_KEY` and runs no compiler.
- Runners are standard GitHub-hosted runners, which are free for public repositories. Larger paid runners, paid services and paid fallbacks are not used.

## Release workflow

| Job | Runs when | Environment | Does |
| --- | --- | --- | --- |
| `build-preview` | A CI push run on `main` succeeds | none | Checks eligibility and the boundary, builds and packages in release mode, prepares unsigned metadata |
| `sign-and-publish-preview` | After `build-preview` | `release-signing` | Signs, verifies, creates a draft prerelease with `--latest=false`, checks the uploaded digest, publishes |
| `approve-stable` | Owner dispatch on `main` | `stable-approval` (owner approval) | Verifies the chosen Preview, its digest, its commit on `main`, the unused tag, newer than current Stable, and the changelog section |
| `sign-and-publish-stable` | After `approve-stable` | `release-signing` | Signs Stable metadata, publishes the same bytes as `v<version>`, marked Latest |
| `deploy-feeds` | After either publish job | `github-pages` | Rebuilds `stable.json` and `preview.json` from published, verified releases and deploys Pages |

**Feeds are rebuilt per channel:**

- With no updater-enabled Stable release, `stable.json` is absent; with no Preview release, `preview.json` is absent. Only the known pre-updater tags `v0.1.0`, `v0.2.0` and `v0.3.0` may lack metadata without failing deployment. The first Preview therefore deploys `preview.json` alone, even while v0.3.0 remains GitHub Latest.
- Stable promotion accepts those same three historical releases as its baseline (builds 28, 29 and 30). Every later Stable release must have verified signed metadata; missing or invalid metadata fails closed.
- A release that exists but has missing or unverifiable metadata, or a mismatched digest, fails the deployment and leaves the previous feeds live. Nothing unsigned or placeholder is ever published.

Every job is gated by the repository variable `QUOTABAR_PUBLISHING == enabled`, which is unset by default. Merging the workflow, or this document, activates nothing.

## Owner setup and activation

These are separate, explicit owner actions. They are not part of any code change.

**A. Implementation.** Merged code, docs and checks. Nothing is active.

**B. Signing setup.**

Status (28 October 2026): steps 1-5 are done, including merged public-key PR #23 and GitHub Pages configuration. Do not generate a new key or replace `QUOTABAR_UPDATE_SIGNING_KEY` unless you are deliberately rotating both; the stored secret must stay the private half of the key in `release-version.json`. Step 6 is optional; account billing confirmation in step 7 remains an owner check. The configured workflow uses standard runners for this public repository.

1. Build the tool, then run it outside every Git checkout:
   ```sh
   swift build -c release --product QuotaReleaseTool
   .build/release/QuotaReleaseTool generate-key --output /absolute/path/outside/any/checkout/quotabar-update.key
   ```
   It prints only the public key. Back up the private key file securely.
2. Create environment **`release-signing`**: deployment branches limited to `main`, no reviewers. Add the private key's contents as its only copy, environment secret `QUOTABAR_UPDATE_SIGNING_KEY`.
3. Create environment **`stable-approval`**, with you as required reviewer and no secrets.
4. Open a reviewed pull request that sets `publicKey` in `release-version.json`.
5. Set **Settings > Pages > Source** to **GitHub Actions**.
6. Optionally turn on GitHub's immutable releases (free). Draft-then-publish stays compatible with it.
7. Confirm in your billing settings that Actions usage for this public repository shows no charge.

**C. Preview activation.** Completed on 28 October 2026 with boundary `a12f999b5610fc3e7750d259f7640b9c81c6f563`. The following steps also describe how to activate after a future pause. After the public-key pull request has merged:

1. Copy the current `main` tip commit SHA into the repository variable **`QUOTABAR_PREVIEW_SINCE`**.
2. Set **`QUOTABAR_PUBLISHING`** to `enabled`.

The next eligible merge after that boundary publishes `preview-<build>` and deploys `preview.json` alone, because an updater-enabled Stable release is still absent. Re-runs or late completions of CI for the boundary commit or anything older are rejected.

GitHub cannot show a stored secret, so the first Preview is also the first check that `QUOTABAR_UPDATE_SIGNING_KEY` matches the committed public key. If it does not, signing fails with "The update signature could not be verified." and nothing is published. Unset `QUOTABAR_PUBLISHING`, replace the secret with the contents of the private key file whose `generate-key` output matched `release-version.json`, set a new `QUOTABAR_PREVIEW_SINCE`, then re-enable.

- **To pause,** unset `QUOTABAR_PUBLISHING`.
- **To resume,** first set a new `QUOTABAR_PREVIEW_SINCE` equal to the `main` tip at that time, then re-enable. Merges made during the pause are never published retroactively.

**D. Qualification.** Use isolated Macs, or macOS user accounts without the Codex or Claude command-line tools. Providers that are not installed are hidden and never polled, so no provider account or reset is involved. On those, install a Preview manually and opt into Preview, then observe:

- migration from the pre-updater releases, including the current 0.3.0;
- check, download, install and relaunch;
- App Management denial and approval;
- launch at login;
- Gatekeeper behavior;
- an interrupted replacement and recovery;
- channel switching;
- missing-feed behavior.

Record the results in [Verification status](VERIFICATION.md) through a pull request. Never exercise a reset to test updates.

**E. First Stable.**

1. Merge a `chore(release): 0.x.y` pull request for a new version after 0.3.0 (for example 0.4.0) that sets `displayVersion`, updates the README Status, download link and checksum example, and moves the Unreleased changelog entries under `## [0.x.y]`. Never reuse the already published v0.3.0 tag.
2. When its Preview build is published, run the **Release** workflow with `preview_tag` and `display_version`.
3. Approve the `stable-approval` environment.

**F. Normal operations.** Merges flow to Preview; you promote Stable when you choose.

**Key loss or compromise:** there is no unsigned path and no automatic key rotation. Installed apps keep working but cannot update until you manually install a build with the new key. Report a suspected compromise as described in [SECURITY.md](../SECURITY.md).

## Normal release operations

- Every change reaches `main` through a Conventional Commit-titled pull request, squash-merged, with an Unreleased changelog entry for user-visible changes. See [CONTRIBUTING.md](../CONTRIBUTING.md).
- After activation, eligible merges become Preview builds automatically.
- To ship Stable: open the `chore(release)` pull request, merge it, promote its Preview build, then approve.
- Never move or reuse a tag, re-upload an asset, mark a Preview as Latest, or rebuild during promotion.
