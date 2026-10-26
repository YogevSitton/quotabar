#!/usr/bin/env python3
"""Checks that release and update documentation stays consistent. Runs offline.

Fails on statements that describe the old manual-only release process, the
retired private prototype, GitHub sign-in for updates or verified installation,
outside the historical sections that legitimately keep them. Also requires the
main documents to link the canonical policy, docs/UPDATES.md, and that policy to
cover its key setup and safety terms. Prints file:line findings; exits 1 on any.
"""
import re
import subprocess
import sys
from pathlib import Path

CANONICAL = 'docs/UPDATES.md'
MUST_LINK = ['README.md', 'CONTRIBUTING.md', 'AGENTS.md', 'SECURITY.md', 'docs/VERIFICATION.md']
CANONICAL_TERMS = ['QUOTABAR_PREVIEW_SINCE', 'QUOTABAR_PUBLISHING', 'release-signing', 'stable-approval',
                   'App Management', 'quarantine', 'release-version.json', 'Latest', 'Install and Relaunch']
# Historical text that must be preserved as written: everything from a heading
# onwards (CHANGELOG release sections) or before it (the publication audit).
HISTORICAL_FROM = {'CHANGELOG.md': '## [0.1.0]'}
HISTORICAL_BEFORE = {'docs/PUBLICATION.md': '## Release checks'}
# Patterns are assembled from fragments so this file never matches itself.
STALE = [
    (re.compile(r'(?i)no in-app ' + r'updater'), 'says there is no updater'),
    (re.compile(r'(?i)updates are ' + r'manual'), 'describes manual-only updates'),
    (re.compile(r'1\.7\.' + r'15'), 'names the pre-publication version'),
    (re.compile(r'8f169' + r'179'), 'names the pre-publication history anchor'),
    (re.compile(r'history' + r'Anchor'), 'names the retired history anchor setting'),
    (re.compile(r'QUOTABAR_FREE_' + r'ONLY_READY'), 'names the retired activation gate'),
    (re.compile(r'quotabar-' + r'channel-'), 'names the retired channel-index releases'),
    (re.compile(r'(?i)\bgh auth ' + r'login\b'), 'asks for GitHub sign-in'),
    (re.compile(r'(?i)(install|sign in to|log in to|authenticate)[^.\n]{0,40}github (cli|command-line ' + r'tool)'),
     'asks users to install or sign in to the GitHub CLI'),
    (re.compile(r'(?i)increments? `?CFBundle' + r'Version'), 'puts version bumps in a script'),
    (re.compile(r'CFBundleVersion`? in `?scripts/' + r'build\.sh'), 'puts version bumps in a script'),
]
VERIFIED_CLAIM = re.compile(r'(?i)\b(update|updates|updater|installation|installer|recovery|rollback)\b'
                            r'[^.\n]{0,60}\b(has|have) been (verified|qualified|' + r'tested)\b')
NEGATION = re.compile(r"(?i)\b(not|never|no|unverified|isn't|hasn't|haven't)\b")


def tracked(root):
    # Tracked plus untracked, non-ignored files, so new documents are checked before they are committed.
    names = subprocess.run(['git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard'],
                           check=True, capture_output=True, text=True).stdout.splitlines()
    return [n for n in names if n.endswith('.md') or (n.startswith('.github/') and n.endswith(('.yml', '.yaml')))
            or (n.startswith('scripts/') and n.endswith('.sh'))]


def historical_lines(name, lines):
    skipped = set()
    if name in HISTORICAL_FROM:
        start = next((i for i, line in enumerate(lines) if line.startswith(HISTORICAL_FROM[name])), None)
        if start is not None:
            skipped.update(range(start, len(lines)))
    if name in HISTORICAL_BEFORE:
        end = next((i for i, line in enumerate(lines) if line.startswith(HISTORICAL_BEFORE[name])), len(lines))
        skipped.update(range(0, end))
    return skipped


def main():
    root = Path(subprocess.run(['git', 'rev-parse', '--show-toplevel'], check=True, capture_output=True, text=True).stdout.strip())
    problems = []
    names = tracked(root)
    if CANONICAL not in names:
        problems.append(f'{CANONICAL}: canonical update policy is missing')
    for name in names:
        lines = (root / name).read_text(encoding='utf-8').splitlines()
        skipped = historical_lines(name, lines)
        for number, line in enumerate(lines):
            if number in skipped:
                continue
            for pattern, reason in STALE:
                if pattern.search(line):
                    problems.append(f'{name}:{number + 1}: stale statement ({reason})')
            if VERIFIED_CLAIM.search(line) and not NEGATION.search(line):
                problems.append(f'{name}:{number + 1}: claims update behavior was verified; record qualification in docs/VERIFICATION.md only after it happens')
    for name in MUST_LINK:
        path = root / name
        if not path.is_file() or 'UPDATES.md' not in path.read_text(encoding='utf-8'):
            problems.append(f'{name}: must link the canonical policy {CANONICAL}')
    if (root / CANONICAL).is_file():
        text = (root / CANONICAL).read_text(encoding='utf-8')
        for term in CANONICAL_TERMS:
            if term not in text:
                problems.append(f'{CANONICAL}: must cover {term}')
    for problem in problems:
        print(problem)
    if problems:
        print(f'Release documentation check failed: {len(problems)} finding(s).')
        return 1
    print('Release documentation check passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
