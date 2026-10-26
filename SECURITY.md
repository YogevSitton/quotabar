# Security policy

## Reporting a vulnerability

Please report security vulnerabilities through [GitHub's private vulnerability reporting](https://github.com/YogevSitton/quotabar/security/advisories/new): open the repository's **Security** tab and choose **Report a vulnerability**. Keep the initial report out of public issues while it is investigated.

Do not open a public issue for a vulnerability, and do not include real tokens, account identifiers, emails, private authorization links or raw CLI output in a report. Describe the problem with synthetic or redacted examples.

You can expect an acknowledgment once the maintainer has seen the report. QuotaBar is maintained in spare time, so there is no guaranteed response or fix time.

## Supported versions

Only the latest release and the `main` branch receive fixes.

## Scope

Relevant reports include anything that could cause QuotaBar to:

- expose or log credentials, tokens, account identifiers or raw CLI output;
- read or write credential stores, or bypass the official CLIs' authentication;
- send a reset request, purchase or other account change without the user's explicit confirmation, or replay one after an uncertain result;
- execute or download code from an unexpected source, including the official Claude Code helper download and its checksum validation.

Issues in the Codex CLI, Claude Code or the providers' services themselves should be reported to OpenAI or Anthropic.
