#!/usr/bin/env python3
"""Check text that is about to become public: pull request titles and
descriptions, branch and tag names, commit messages or any pasted text.

Reads the named files, or standard input for '-' or no file, and applies the
privacy rules of scripts/audit-public-tree.py to every line: credential-shaped
strings, absolute home-directory paths, email addresses other than GitHub
noreply and system addresses, no-reply attribution addresses and reserved
example domains, and private terms. With --revs, checks instead the author and
committer names and the message of each commit those git log arguments select.
Findings name the category, the line and the commit, never the matched text.

Private terms are salted SHA-256 hashes in an untracked file, by default
quotabar-private-terms.txt in the clone's git directory. --add-term reads one
term from standard input and appends its hash there. A hash of a short word can
be reversed by guessing, so that file must never be published.
"""
import argparse
import importlib.util
import os
import secrets
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
TERMS_HEADER = '''# Private terms for the public-record checks of this clone; never commit or publish this file,
# because a salted hash of a short word can be reversed by guessing. One line per term:
# sha256:<salt>:<hex of sha256("<salt>:<lowercase term>")>. Add one with
# python3 scripts/check-public-text.py --add-term (type the term, press Return).
'''


def load_audit():
    spec = importlib.util.spec_from_file_location('audit_public_tree', SCRIPTS / 'audit-public-tree.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


AUDIT = load_audit()


def findings(text, terms):
    return [(number, finding) for number, line in enumerate(text.splitlines(), 1)
            for finding in AUDIT.line_findings(line, terms)]


def repository_root():
    try:
        return AUDIT.git(Path.cwd(), 'rev-parse', '--show-toplevel').strip() or None
    except (subprocess.CalledProcessError, OSError):
        return None


def commit_texts(revs):
    """[(label, names and message)] for each commit the git log arguments select."""
    output = AUDIT.git(Path.cwd(), 'log', '-z', '--no-show-signature', '--format=%H%x1f%an%n%cn%n%B', *revs)
    texts = []
    for record in output.split('\0'):
        sha, separator, text = record.strip('\n').partition('\x1f')
        if separator:
            texts.append((f'commit {sha[:12]}', text))
    return texts


def add_term(path):
    if sys.stdin.isatty():
        print('Private term: ', end='', file=sys.stderr, flush=True)
    word = sys.stdin.readline().strip().lower()
    if not AUDIT.WORD.fullmatch(word):
        print('Enter one term made of letters and digits; matching ignores case.', file=sys.stderr)
        return 2
    salt = secrets.token_hex(8)
    is_new = not path.exists()
    with open(path, 'a', encoding='utf-8') as handle:
        if is_new:
            handle.write(TERMS_HEADER)
        handle.write(f'sha256:{salt}:{AUDIT.term_digest(salt, word)}\n')
    os.chmod(path, 0o600)
    print(f'Added a private term to {path}.')
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('files', nargs='*', metavar='FILE', help="files to check; '-' or none reads standard input")
    parser.add_argument('--label', help='name used for the input in findings')
    parser.add_argument('--private-terms', metavar='PATH', help='file of salted term hashes (default: $QUOTABAR_PRIVATE_TERMS, '
                        f'else {AUDIT.PRIVATE_TERMS_FILE} in the git directory, when present)')
    parser.add_argument('--add-term', action='store_true', help='read one term from standard input and append its hash to the private-terms file')
    parser.add_argument('--quiet', action='store_true', help='print nothing when the check passes')
    parser.add_argument('--revs', nargs=argparse.REMAINDER, metavar='REV', help='check the names and message of each commit '
                        'these git log arguments select; must come last')
    arguments = parser.parse_args(argv)
    root = repository_root()
    if arguments.private_terms:
        terms_path = Path(arguments.private_terms)
        if not arguments.add_term and not terms_path.is_file():
            parser.error(f'{arguments.private_terms} is not a file')
    else:
        terms_path = AUDIT.default_private_terms_path(root) if root else None
    if arguments.add_term:
        if terms_path is None:
            parser.error('not in a git repository; pass --private-terms PATH')
        return add_term(terms_path)
    try:
        terms = AUDIT.load_private_terms(terms_path)
    except ValueError as error:
        print(error)
        return 1
    if arguments.revs is not None:
        if not arguments.revs:
            parser.error('--revs needs at least one revision argument')
        if arguments.files:
            parser.error('give files or --revs, not both')
        try:
            texts = commit_texts(arguments.revs)
        except subprocess.CalledProcessError as error:
            print((error.stderr or '').strip() or 'git failed', file=sys.stderr)
            return 2
    else:
        texts = []
        for name in arguments.files or ['-']:
            data = sys.stdin.buffer.read() if name == '-' else Path(name).read_bytes()
            texts.append((arguments.label or ('stdin' if name == '-' else name), data.decode('utf-8', errors='replace')))
    problems = [f'{label}:{number}: {finding}' for label, text in texts for number, finding in findings(text, terms)]
    for problem in problems:
        print(problem)
    if problems:
        print(f'Public text check failed: {len(problems)} finding(s).')
        return 1
    if not arguments.quiet:
        print('Public text check passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
