# Security policy

## Reporting a vulnerability

Please report security vulnerabilities through [GitHub's private vulnerability reporting](https://github.com/YogevSitton/quotabar/security/advisories/new): open the repository's **Security** tab and choose **Report a vulnerability**. Keep the initial report out of public issues while it is investigated.

Do not open a public issue for a vulnerability, and do not include real tokens, account identifiers, emails, private authorization links or raw CLI output in a report. Describe the problem with synthetic or redacted examples.

You can expect an acknowledgment once the maintainer has seen the report. QuotaBar is maintained in spare time, so there is no guaranteed response or fix time.

## Supported versions

Only the latest Stable release, the latest Preview build and the `main` branch receive fixes. Fixes ship as newer builds; published releases are never replaced. See [docs/UPDATES.md](docs/UPDATES.md) for channels and update integrity.

## Scope

Relevant reports include anything that could cause QuotaBar to:

- expose or log credentials, tokens, account identifiers or raw CLI output;
- read or write credential stores, or bypass the official CLIs' authentication;
- send a reset request, purchase or other account change without the user's explicit confirmation, or replay one after an uncertain result;
- execute or download code from an unexpected source, including the official Claude Code helper download and its checksum validation;
- accept update metadata or an archive that is unsigned, signed by another key, altered, for another app or channel, or older than the installed build;
- install or replace the app without a fresh Install and Relaunch click, or damage the installed app when macOS denies the replacement;
- expose the release signing key to pull-request or fork code, or let a Preview build become GitHub's Latest release.

If you believe the update signing key is compromised, report it privately as above.

Issues in the Codex CLI, Claude Code or the providers' services themselves should be reported to OpenAI or Anthropic.
