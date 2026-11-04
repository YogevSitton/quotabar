#!/usr/bin/env python3
"""Audit what this repository publishes for content that must stay private.

By default, audits the tracked files of the working tree: credential-shaped
strings, absolute home-directory paths, email addresses other than public
noreply, system and example ones, private terms, long Unicode dashes in
authored text, metadata in PNG, ICNS and PDF files, tracked path names and
symlink targets, and missing README image targets.

With --revs, audits instead every file version and path that the given git
rev-list arguments introduce, for example --revs origin/main..HEAD, with the
privacy rules only. The pre-push hook and the PR hygiene workflow use this, so
a leak that one commit adds and a later commit removes is still found.

Private terms are salted SHA-256 hashes kept out of the repository, by default
in quotabar-private-terms.txt in the clone's git directory. A hash of a short
word can be reversed by guessing, so that file must never be published.
Optional flags add forbidden terms, required files, a private-log phrase check
for Markdown and a clean-worktree requirement. Runs offline and prints file:line
for each finding; exits 1 when anything is found and 2 on usage or git errors.
"""
import argparse
import hashlib
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

# Patterns are assembled from fragments so this file never matches itself.
CREDENTIAL_PATTERNS = [
    ('Anthropic API key', re.compile(r'\bsk' + r'-ant-[A-Za-z0-9_-]{8,}')),
    ('API secret key', re.compile(r'\bsk' + r'-[A-Za-z0-9_-]{20,}')),
    ('GitHub token', re.compile(r'\bgh' + r'[pousr]_[A-Za-z0-9]{20,}')),
    ('GitHub fine-grained token', re.compile(r'\bgithub' + r'_pat_[A-Za-z0-9_]{20,}')),
    ('AWS access key', re.compile(r'\bAK' + r'IA[0-9A-Z]{16}\b')),
    ('private key', re.compile(r'-----BEGIN [A-Z ]*PRIV' + r'ATE KEY(?: BLOCK)?-----')),
    ('JSON web token', re.compile(r'\bey' + r'J[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.')),
    ('bearer token', re.compile(r'(?i)\bbear' + r'er\s+[A-Za-z0-9._~+/=-]{20,}')),
]
# A home folder with or without a trailing slash, except the shared folder and the CI runner
# account, and the dashed form that tools use in folder names (a slash, then -Users-<name>).
HOME_PATH = re.compile(r'/(?:' + 'Us' + 'ers|ho' + 'me)/(?!(?:Shared|runner)(?![A-Za-z0-9._-]))[A-Za-z0-9._-]+'
                       r'|/-(?:' + 'Us' + 'ers|ho' + 'me)-[A-Za-z0-9]')
# An address that does not follow a URL or path character, so URL userinfo is not an address.
EMAIL = re.compile(r'(?<![A-Za-z0-9._%+/-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
# GitHub noreply addresses (bots included), GitHub system senders such as Dependabot's sign-off,
# the SSH user of public Git hosts, no-reply attribution addresses, reserved example domains, and
# package specs whose version ends in a prerelease label.
PUBLIC_EMAIL = re.compile(r'(?i)^(?:[0-9]+\+)?[A-Za-z0-9\[\]-]+@users\.noreply\.github\.com$'
                          r'|^no-?reply@[A-Za-z0-9.-]+$'
                          r'|^(?:support|notifications|git)@github\.com$'
                          r'|^git@(?:gitlab\.com|bitbucket\.org)$'
                          r'|^[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)*(?:example\.(?:com|net|org)|[A-Za-z0-9-]+\.(?:invalid|test|example))$'
                          r'|^[^@]+@[0-9]+\.[0-9]+\.[0-9]+-')
LONG_DASHES = re.compile('[' + chr(0x2013) + chr(0x2014) + ']')
DASH_CHECKED_SUFFIXES = {'.md', '.swift', '.py', '.sh', '.yml', '.yaml'}
PRIVATE_LOG_PHRASE = re.compile(r'(?i)\bthe ' + r'human\b')
README_IMAGE = re.compile(r'!\[[^\]]*\]\(([^)\s]+)\)')
ARTWORK_SUFFIXES = {'.png', '.icns', '.pdf'}
PRIVATE_TERMS_FILE = 'quotabar-private-terms.txt'
PRIVATE_TERM_LINE = re.compile(r'^sha256:([0-9a-f]{8,64}):([0-9a-f]{64})$')
WORD = re.compile(r'[a-z0-9]+')
RUN = re.compile(r'[A-Za-z0-9]+')
PIECE = re.compile(r'[A-Z]?[a-z]+|[A-Z]+(?![a-z])|[0-9]+')

PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'
PNG_KEPT_ANCILLARY = {b'tRNS', b'sRGB', b'gAMA', b'cHRM', b'iCCP', b'pHYs'}


def git(root, *arguments):
    return subprocess.run(['git', *arguments], cwd=root, check=True, capture_output=True,
                          encoding='utf-8', errors='replace', stdin=subprocess.DEVNULL).stdout


def tracked_entries(root):
    """{path: mode} for every path in the index."""
    entries = {}
    for record in git(root, 'ls-files', '-s', '-z').split('\0'):
        meta, _, path = record.partition('\t')
        if path:
            entries.setdefault(path, meta.split(' ', 1)[0])
    return entries


def png_findings(data):
    if not data.startswith(PNG_SIGNATURE):
        return ['not a valid PNG file']
    findings, offset = [], len(PNG_SIGNATURE)
    while offset + 8 <= len(data):
        length, kind = struct.unpack('>I4s', data[offset:offset + 8])
        if offset + 12 + length > len(data):
            return findings + ['truncated PNG chunk']
        if not kind[:1].isupper() and kind not in PNG_KEPT_ANCILLARY:
            findings.append(f'metadata chunk {kind.decode("latin-1")} (strip with scripts/strip-png-metadata.py)')
        if kind == b'IEND':
            return findings + (['data after PNG end'] if offset + 12 + length != len(data) else [])
        offset += 12 + length
    return findings + ['missing PNG end chunk']


def artwork_findings(data):
    if data.startswith(PNG_SIGNATURE):
        return png_findings(data)
    if data.startswith(b'icns'):
        findings, offset = [], 8
        if len(data) < 8 or struct.unpack('>I', data[4:8])[0] != len(data):
            return ['invalid ICNS length']
        while offset < len(data):
            if offset + 8 > len(data):
                return findings + ['truncated ICNS header']
            kind, length = struct.unpack('>4sI', data[offset:offset + 8])
            if length < 8 or offset + length > len(data):
                return findings + ['invalid ICNS element']
            part = data[offset + 8:offset + length]
            if part.startswith(PNG_SIGNATURE):
                findings += [kind.decode('latin-1') + ': ' + item for item in png_findings(part)]
            offset += length
        return findings
    if data.startswith(b'%PDF'):
        # Authored vector PDFs have no reason to carry build-machine metadata.
        pattern = rb'/(?:CreationDate|ModDate|Producer|Author|Creator|Title|Subject|Keywords)\s*\('
        return ['PDF build or author metadata'] if re.search(pattern, data) else []
    return []


def default_private_terms_path(root):
    """$QUOTABAR_PRIVATE_TERMS, else quotabar-private-terms.txt in the clone's git directory."""
    if os.environ.get('QUOTABAR_PRIVATE_TERMS'):
        return Path(os.environ['QUOTABAR_PRIVATE_TERMS'])
    try:
        common = git(root, 'rev-parse', '--git-common-dir').strip()
    except (subprocess.CalledProcessError, OSError):
        return None
    return (Path(root) / common / PRIVATE_TERMS_FILE).resolve()


def load_private_terms(path):
    """Returns [(salt, digest)] from a private-terms file; no path or no file means no terms."""
    terms = []
    if path is None or not Path(path).is_file():
        return terms
    for number, line in enumerate(Path(path).read_text(encoding='utf-8').splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        match = PRIVATE_TERM_LINE.match(line)
        if not match:
            raise ValueError(f'{path}:{number}: expected sha256:<salt>:<digest>')
        terms.append(match.groups())
    return terms


def term_digest(salt, word):
    return hashlib.sha256(f'{salt}:{word}'.encode()).hexdigest()


def has_private_term(line, terms):
    """Case-insensitive match of whole words and of their camelCase and digit-separated parts."""
    words = set()
    for run in RUN.findall(line):
        words.add(run.lower())
        words.update(piece.lower() for piece in PIECE.findall(run))
    return any(term_digest(salt, word) == digest for word in words for salt, digest in terms)


def line_findings(line, private_terms=()):
    """The privacy rules for one line of public text."""
    found = [f'possible {label}' for label, pattern in CREDENTIAL_PATTERNS if pattern.search(line)]
    if HOME_PATH.search(line):
        found.append('absolute home-directory path')
    if any(not PUBLIC_EMAIL.match(address) for address in EMAIL.findall(line)):
        found.append('email address that is not a public noreply address')
    if private_terms and has_private_term(line, private_terms):
        found.append('private term (hash match)')
    return found


def text_findings(name, text, forbidden=(), public_docs=False, private_terms=(), style=True):
    findings = []
    suffix = Path(name).suffix.lower()
    for number, line in enumerate(text.splitlines(), 1):
        findings += [(number, finding) for finding in line_findings(line, private_terms)]
        if style and suffix in DASH_CHECKED_SUFFIXES and LONG_DASHES.search(line):
            findings.append((number, 'long Unicode dash; use an ASCII hyphen'))
        for term in forbidden:
            if term in line:
                findings.append((number, f'forbidden term {term!r}'))
        if style and public_docs and suffix == '.md' and PRIVATE_LOG_PHRASE.search(line):
            findings.append((number, 'private-log phrasing; refer to "the maintainer"'))
    return findings


def content_findings(label, name, data, forbidden=(), public_docs=False, private_terms=(), style=True):
    if Path(name).suffix.lower() in ARTWORK_SUFFIXES:
        return [f'{label}: {finding}' for finding in artwork_findings(data)]
    if b'\0' in data:
        return []
    text = data.decode('utf-8', errors='replace')
    return [f'{label}:{number}: {finding}'
            for number, finding in text_findings(name, text, forbidden, public_docs, private_terms, style)]


def audit(root, forbidden=(), required=(), public_docs=False, require_clean=False, private_terms=()):
    problems = []
    entries = tracked_entries(root)
    for name, mode in entries.items():
        problems += [f'{name}: path: {finding}' for finding in line_findings(name, private_terms)]
        path = root / name
        if mode == '120000' and path.is_symlink():
            # Git publishes a symlink's target text, not the file it points to.
            problems += [f'{name}: symlink target: {finding}' for finding in line_findings(os.readlink(path), private_terms)]
            continue
        if path.is_file():
            problems += content_findings(name, name, path.read_bytes(), forbidden, public_docs, private_terms)
    readme = root / 'README.md'
    if readme.is_file():
        for number, line in enumerate(readme.read_text(encoding='utf-8').splitlines(), 1):
            for target in README_IMAGE.findall(line):
                if '://' not in target and target.split('#')[0] not in entries:
                    problems.append(f'README.md:{number}: image target {target} is not a tracked file')
    for name in required:
        if name not in entries:
            problems.append(f'{name}: required file is not tracked')
    if require_clean:
        status = git(root, 'status', '--porcelain')
        if status.strip():
            problems.append('worktree is not clean:\n' + status.rstrip())
    return problems


def revision_problems(root, revs, private_terms=()):
    """Privacy findings in every object and path that the rev-list arguments introduce."""
    names = {}
    for line in git(root, 'rev-list', '--objects', *revs).splitlines():
        sha, _, path = line.partition(' ')
        names.setdefault(sha, path)
    paths = {path for path in names.values() if path}
    changed = git(root, 'log', '-z', '-m', '--no-show-signature', '--name-only', '--format=', *revs).split('\0')
    paths.update(path.strip() for path in changed if path.strip())
    problems = [f'{path}: path: {finding}' for path in sorted(paths) for finding in line_findings(path, private_terms)]
    if not names:
        return problems
    kinds = subprocess.run(['git', 'cat-file', '--batch-check=%(objectname) %(objecttype)'], cwd=root, check=True,
                           input='\n'.join(names) + '\n', capture_output=True, text=True).stdout.split()
    blobs = [sha for sha, kind in zip(kinds[0::2], kinds[1::2]) if kind == 'blob']
    reader = subprocess.Popen(['git', 'cat-file', '--batch'], cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for sha in blobs:
            reader.stdin.write(sha.encode() + b'\n')
            reader.stdin.flush()
            header = reader.stdout.readline().split()
            data = reader.stdout.read(int(header[2]))
            reader.stdout.read(1)
            name = names[sha] or sha
            problems += content_findings(f'{name} ({sha[:12]})', name, data, private_terms=private_terms, style=False)
    finally:
        reader.stdin.close()
        reader.wait()
    return problems


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--forbid', action='append', default=[], metavar='TERM', help='fail on this case-sensitive substring')
    parser.add_argument('--require-file', action='append', default=[], metavar='PATH', help='fail unless this path is tracked')
    parser.add_argument('--public-docs', action='store_true', help='fail on private-log phrasing in Markdown')
    parser.add_argument('--require-clean', action='store_true', help='fail when git status reports any change')
    parser.add_argument('--private-terms', metavar='PATH', help='file of salted term hashes (default: $QUOTABAR_PRIVATE_TERMS, else '
                        f'{PRIVATE_TERMS_FILE} in the git directory, when present)')
    parser.add_argument('--quiet', action='store_true', help='print nothing when the audit passes')
    parser.add_argument('--revs', nargs=argparse.REMAINDER, metavar='REV', help='audit what these git rev-list arguments '
                        'introduce instead of the working tree; must come last')
    arguments = parser.parse_args(argv)
    if arguments.revs is not None and not arguments.revs:
        parser.error('--revs needs at least one revision argument')
    if arguments.private_terms and not Path(arguments.private_terms).is_file():
        parser.error(f'{arguments.private_terms} is not a file')
    try:
        root = Path(git(Path.cwd(), 'rev-parse', '--show-toplevel').strip())
        terms_path = Path(arguments.private_terms) if arguments.private_terms else default_private_terms_path(root)
        private_terms = load_private_terms(terms_path)
        if arguments.revs is not None:
            problems = revision_problems(root, arguments.revs, private_terms)
        else:
            problems = audit(root, arguments.forbid, arguments.require_file, arguments.public_docs,
                             arguments.require_clean, private_terms)
    except ValueError as error:
        problems = [str(error)]
    except subprocess.CalledProcessError as error:
        print((error.stderr or '').strip() or 'git failed', file=sys.stderr)
        return 2
    for problem in problems:
        print(problem)
    if problems:
        print(f'Audit failed: {len(problems)} finding(s).')
        return 1
    if not arguments.quiet:
        print('Audit passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
