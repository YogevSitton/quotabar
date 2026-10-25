#!/usr/bin/env python3
"""Audit Git-tracked files for content that must not be published.

Checks credential-shaped strings, absolute home-directory paths, long Unicode
dashes in authored text, metadata chunks in PNG files and missing README image
targets. Optional flags add forbidden terms, required files, a private-log
phrase check for Markdown, and a clean-worktree requirement. Runs offline and
prints file:line for each finding; exits 1 when anything is found.
"""
import argparse
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
    ('private key', re.compile(r'-----BEGIN [A-Z ]*PRIV' + r'ATE KEY-----')),
    ('JSON web token', re.compile(r'\bey' + r'J[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.')),
    ('bearer token', re.compile(r'(?i)\bbear' + r'er\s+[A-Za-z0-9._~+/=-]{20,}')),
]
HOME_PATH = re.compile(r'/(?:' + 'Us' + 'ers|ho' + 'me)/[A-Za-z0-9._-]+/')
LONG_DASHES = re.compile('[' + chr(0x2013) + chr(0x2014) + ']')
DASH_CHECKED_SUFFIXES = {'.md', '.swift', '.py', '.sh', '.yml', '.yaml'}
PRIVATE_LOG_PHRASE = re.compile(r'(?i)\bthe ' + r'human\b')
README_IMAGE = re.compile(r'!\[[^\]]*\]\(([^)\s]+)\)')

PNG_SIGNATURE = b'\x89PNG\r\n\x1a\n'
PNG_KEPT_ANCILLARY = {b'tRNS', b'sRGB', b'gAMA', b'cHRM', b'iCCP', b'pHYs'}


def git(root, *arguments):
    return subprocess.run(['git', *arguments], cwd=root, check=True, capture_output=True, text=True).stdout


def tracked_files(root):
    names = git(root, 'ls-files', '-z').split('\0')
    return [name for name in names if name and (root / name).is_file()]


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


def text_findings(name, text, forbidden, public_docs):
    findings = []
    suffix = Path(name).suffix.lower()
    for number, line in enumerate(text.splitlines(), 1):
        for label, pattern in CREDENTIAL_PATTERNS:
            if pattern.search(line):
                findings.append((number, f'possible {label}'))
        if HOME_PATH.search(line):
            findings.append((number, 'absolute home-directory path'))
        if suffix in DASH_CHECKED_SUFFIXES and LONG_DASHES.search(line):
            findings.append((number, 'long Unicode dash; use an ASCII hyphen'))
        for term in forbidden:
            if term in line:
                findings.append((number, f'forbidden term {term!r}'))
        if public_docs and suffix == '.md' and PRIVATE_LOG_PHRASE.search(line):
            findings.append((number, 'private-log phrasing; refer to "the maintainer"'))
    return findings


def audit(root, forbidden=(), required=(), public_docs=False, require_clean=False):
    problems = []
    names = tracked_files(root)
    tracked = set(names)
    for name in names:
        data = (root / name).read_bytes()
        if Path(name).suffix.lower() in {'.png', '.icns', '.pdf'}:
            problems += [f'{name}: {finding}' for finding in artwork_findings(data)]
            continue
        if b'\0' in data:
            continue
        try:
            text = data.decode('utf-8')
        except UnicodeDecodeError:
            continue
        problems += [f'{name}:{number}: {finding}' for number, finding in text_findings(name, text, forbidden, public_docs)]
    readme = root / 'README.md'
    if readme.is_file():
        for number, line in enumerate(readme.read_text(encoding='utf-8').splitlines(), 1):
            for target in README_IMAGE.findall(line):
                if '://' not in target and target.split('#')[0] not in tracked:
                    problems.append(f'README.md:{number}: image target {target} is not a tracked file')
    for name in required:
        if name not in tracked:
            problems.append(f'{name}: required file is not tracked')
    if require_clean:
        status = git(root, 'status', '--porcelain')
        if status.strip():
            problems.append('worktree is not clean:\n' + status.rstrip())
    return problems


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--forbid', action='append', default=[], metavar='TERM', help='fail on this case-sensitive substring')
    parser.add_argument('--require-file', action='append', default=[], metavar='PATH', help='fail unless this path is tracked')
    parser.add_argument('--public-docs', action='store_true', help='fail on private-log phrasing in Markdown')
    parser.add_argument('--require-clean', action='store_true', help='fail when git status reports any change')
    arguments = parser.parse_args(argv)
    root = Path(git(Path.cwd(), 'rev-parse', '--show-toplevel').strip())
    problems = audit(root, arguments.forbid, arguments.require_file, arguments.public_docs, arguments.require_clean)
    for problem in problems:
        print(problem)
    if problems:
        print(f'Audit failed: {len(problems)} finding(s).')
        return 1
    print('Audit passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
