# Contributing to QuotaBar

Thanks for helping. QuotaBar reads subscription usage for real accounts, so a few rules matter more than usual. Read [AGENTS.md](AGENTS.md) before changing code: it holds the full project, credential, reset and layout rules, and it applies to human and AI contributors alike.

None of this is meant to be bureaucratic. The goal is a `main` branch people can trust, a history that explains itself, and releases users can follow.

## Ground rules

- **Never exercise a reset action.** Do not click Use reset, confirm a reset, send a reset request, or spend reset credits while developing or testing, on any account. Review reset changes statically; current verification is compile-only.
- **Use synthetic fixtures only.** Tests must not contact a provider, read a real account, or depend on local caches. Never commit real account identifiers, emails, tokens, raw CLI output, runtime caches, downloaded helper binaries or app bundles.
- **Keep monitoring read-only.** No model prompts, purchases, subscription changes, token refresh or direct credential access.
- **Unknown stays unknown.** Missing or malformed provider data must never become zero usage, full availability or zero credits.
- **Use ASCII hyphens** for every authored dash in UI text and documentation.
- **Be kind.** See the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you start

- **Small fixes** (typos, an obvious bug, a docs correction): just open a pull request.
- **Anything bigger** (a new feature, a UI change, a new provider, a refactor): open an issue first, or comment on an existing one, so we can agree on the approach before you spend time on it. The menu bar and popup layout is deliberately minimal (see AGENTS.md), so UI ideas especially benefit from a quick chat first.
- If you pick up an issue, say so in a comment so nobody else duplicates the work.

## How changes land

**Every change reaches `main` through a pull request**, including the maintainer's own and those made with AI assistants. Nobody pushes to `main` directly.

1. **Branch from `main`.** Name it `<type>/<short-topic>`, for example `fix/claude-backoff` or `docs/install-steps`. Tool-generated branch names are fine too.
2. **Commit as you like on the branch.** Pull requests are squash-merged, so work-in-progress commits are fine. Open a **draft** pull request early if you want feedback.
3. **Title the pull request as a [Conventional Commit](https://www.conventionalcommits.org/).** The title becomes the single commit on `main` and feeds the changelog, so it is the one message that has to be right. A CI check validates the format.
4. **Fill in the template**, link the issue (`Closes #12`) and describe what you verified.
5. **Wait for CI to pass**, then for review. The maintainer reviews every outside contribution. While there is a single maintainer, the maintainer's own pull requests may be merged once CI is green, but still go through a pull request so the change is visible and revertible.
6. **Squash and merge.** The branch is deleted automatically.

### Pull request titles

```
<type>(<optional scope>): <what changes, in the imperative>
```

| Type | Use it for | Release impact |
| --- | --- | --- |
| `feat` | Something new a user can see or use | minor |
| `fix` | A bug fix a user would notice | patch |
| `perf` | Faster or lighter, same behavior | patch |
| `refactor` | Code change with no behavior change | none |
| `docs` | Documentation only | none |
| `test` | Tests or fixtures only | none |
| `build` | Build scripts, packaging, artwork pipeline | none |
| `ci` | GitHub Actions and repository automation | none |
| `chore` | Anything else that does not touch the app | none |
| `revert` | Reverting an earlier change | depends |

Scopes are optional; useful ones are `codex`, `claude`, `menubar`, `popup`, `details`, `core` and `release`. Mark a breaking change with `!`, such as `feat(core)!: drop macOS 13 support`, and explain it in the description.

Examples:

```
fix(claude): keep saved readings visible during transient failures
feat(popup): show the reset countdown next to each expiry
docs: explain checksum verification in the install steps
```

Keep the description short and lowercase-first; no trailing period.

### What makes a good pull request

- One focused change. Two unrelated fixes are two pull requests.
- Add or update synthetic-fixture tests for behavior changes in `Sources/QuotaCore/`.
- Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for anything a user would notice (`feat`, `fix`, `perf`, breaking changes). Write it for users, not for developers.
- Update `docs/VERIFICATION.md` when a change affects what has or has not been verified.
- Screenshots must not show emails, names, account or organization IDs, private authorization links, or other personal data. Prefer offline renders of the current UI with synthetic data, and label them as examples. Record their source revision and capture method in [the screenshot guide](docs/SCREENSHOTS.md); strip image metadata and visually review each image before committing it.
- If an AI assistant wrote a meaningful part of the change, say so in the description. The same rules and the same review apply.

## Build and review

For toolchain setup and a first build, follow [Build from source](README.md#build-from-source). Requires macOS 14+ and Swift 5.9 or newer. Local build verification has covered Apple Silicon; Intel remains unverified.

Run these commands from the repository root. They build and inspect the app without launching it:

```sh
./scripts/build.sh
swift build --build-tests --disable-sandbox
python3 scripts/audit-public-tree.py --public-docs
codesign --verify --deep --strict dist/QuotaBar.app
```

`./scripts/build.sh` must leave Git-tracked files unchanged. If you change the app icon drawing, run `./scripts/build-icon.sh` and commit the regenerated artwork in the same pull request.

Do not execute tests, live diagnostics, sign-in or reset actions under the current verification restriction. The maintainer must explicitly change that restriction first. Never paste raw provider output or identifiers into an issue or pull request.

Offline documentation renders may use synthetic fixtures without starting provider monitoring, loading account or recovery files, or invoking any controls. They demonstrate presentation only and do not establish live-provider or reset verification.

CI compiles the app and test targets on macOS, audits the public tree and checks the pull request title; it does not execute tests. Workflows from first-time contributors wait for maintainer approval before running.

## Reviews

- Reviews are about the change, never the person. Explain the why behind a request, and say when something is only a suggestion (`nit:`).
- Expect a first response within about a week. QuotaBar is maintained in spare time; a polite nudge after that is welcome.
- Pull requests with no activity for a month after a review request may be closed. They can always be reopened.

## Versions and releases

QuotaBar uses [Semantic Versioning](https://semver.org/). While the version is `0.x`, releases are public previews: a minor bump (`0.2.0`) may include breaking changes, and patch bumps (`0.1.1`) are fixes only.

Releases are cut by the maintainer from `main`:

1. Open a `chore(release): 0.x.y` pull request that bumps `CFBundleShortVersionString` and increments `CFBundleVersion` in `scripts/build.sh`, updates the version in the README's Status section and checksum example, and moves the **Unreleased** changelog entries under the new version and date.
2. After it merges, tag the squashed commit it created on `main` as `v0.x.y` and run `./scripts/package-release.sh`.
3. Publish a GitHub release for the tag with the changelog section as notes, and attach the zip and its `.sha256` file.

Tags and releases are never moved or rewritten once published. A broken release is fixed by a new patch release.

## Labels

Issues and pull requests use a small set of labels: `bug`, `enhancement`, `documentation`, `accessibility`, `question`, `good first issue`, `help wanted`, `duplicate`, `invalid` and `wontfix`. The maintainer applies them; you do not need to.

## Reporting bugs and security issues

Use the issue templates for bugs and feature requests. Report security vulnerabilities privately, as described in [SECURITY.md](SECURITY.md), not in a public issue.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
