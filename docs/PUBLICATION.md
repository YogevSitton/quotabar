# Public repository preparation

The publication audit covered all 32 commits reachable from the private remote's branches and pull-request ref, plus the two additional local-only commits (34 unique commits, 287 unique file blobs). The public repository publishes only the rewritten main branch, with one release-preparation commit. Unmerged development branches and old pull-request discussions were not published, and the previous private repository has been deleted.

The audit included Gitleaks 8.30.1 with full-history scanning and redacted output, an independent scan of every unique blob and commit message/identity for emails, private home paths, account-like identifiers, UUIDs and IP addresses, and PNG, ICNS and PDF metadata inspection. No credential leaks or personal home paths were detected. The personal commit-author/committer email was replaced with the owner's GitHub noreply address. Synthetic fixture addresses and the coding assistant's public attribution address remain.

Four previously flagged historical artwork blobs were removed. Other historical PNG and embedded ICNS PNG metadata and PDF build metadata were stripped as well. Pixel data and PDF drawing streams were compared before and after sanitization. Certificate contact addresses and a generated-image identifier existed only inside the removed artwork. The private development tool's name was removed from public file contents and commit messages.

The rewritten history is rescanned before upload. Only the rewritten main branch is pushed to a newly created private repository; no old refs, tags, pull requests or audit reports containing private findings are copied. Security settings are verified as GitHub makes them available. On GitHub Free, some settings become available only when a repository is public.

## Release checks and remaining work

- Compile the release app and test targets without executing tests.
- Verify the ad-hoc signature and checksum of the extracted release archive.
- Include the MIT license and provider artwork notice inside the app bundle.
- Omit obsolete screenshots; current captures require a separate approved read-only session.
- Keep monitoring, sign-in and reset verification restrictions in place.
- Clearly label the downloadable app an early preview: Developer ID signing, notarization, a supported update channel, broader account compatibility and Intel validation remain incomplete.

Pattern scans and metadata inspection reduce exposure risk; they do not prove the absence of every possible secret or vulnerability. Future changes still need review and repository security scanning.
