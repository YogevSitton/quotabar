#!/usr/bin/env python3
"""Check that commits carry only GitHub noreply addresses, so a personal email
address never enters the public record.

Without --revs, checks the author and committer identity Git would use for a
new commit here, including GIT_* environment overrides; inside a commit hook
that also covers --author and the original author of an --amend. With --revs,
checks the author and committer of every commit that git log selects with those
arguments, for example --revs origin/main..HEAD or --revs <sha> --not --remotes=origin.
Findings name commits only, never the address. Exits 1 when a check fails and
2 on usage or git errors.
"""
import argparse
import re
import subprocess
import sys

PUBLIC = re.compile(r'^(?:[0-9]+\+)?[A-Za-z0-9\[\]-]+@users\.noreply\.github\.com$|^noreply@github\.com$')
IDENT = re.compile(r'<([^>]*)>')
SET_ADDRESS = '''Set your GitHub noreply address (GitHub > Settings > Emails):
  git config user.email <id>+<login>@users.noreply.github.com'''
REMEDY_NEXT = SET_ADDRESS + '''
or drop --author and unset GIT_AUTHOR_EMAIL or GIT_COMMITTER_EMAIL if they name another
address, then run the same git command again. When amending another author's commit, add
--reset-author.'''
REMEDY_REVS = SET_ADDRESS + '''
then rewrite the commits listed above: the last one with
  git commit --amend --no-edit --reset-author
or every commit on a branch with
  git rebase <base> --exec 'git commit --amend --no-edit --reset-author'
A fix commit is not enough: the listed commits would still be published.'''


def git(*arguments):
    return subprocess.run(['git', *arguments], check=True, capture_output=True, encoding='utf-8',
                          errors='replace', stdin=subprocess.DEVNULL).stdout


def configured_identity_problems():
    problems = []
    for role in ('AUTHOR', 'COMMITTER'):
        try:
            match = IDENT.search(git('var', f'GIT_{role}_IDENT'))
        except subprocess.CalledProcessError:
            match = None
        if not match or not PUBLIC.match(match.group(1)):
            problems.append(f'{role.lower()} address for the next commit is not a GitHub noreply address')
    return problems


def commit_problems(revs):
    problems = []
    for record in git('log', '--no-show-signature', '--format=%H%x1f%ae%x1f%ce', *revs).splitlines():
        fields = record.split('\x1f')
        if len(fields) != 3:
            raise ValueError(f'unexpected git log output: {record[:60]!r}')
        sha, author, committer = fields
        if not PUBLIC.match(author):
            problems.append(f'{sha[:12]}: author email is not a GitHub noreply address')
        if not PUBLIC.match(committer):
            problems.append(f'{sha[:12]}: committer email is not a GitHub noreply address')
    return problems


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--quiet', action='store_true', help='print nothing when the check passes')
    parser.add_argument('--revs', nargs=argparse.REMAINDER, metavar='REV', help='git log revision arguments selecting the '
                        'commits to check; must come last')
    arguments = parser.parse_args(argv)
    if arguments.revs is not None and not arguments.revs:
        parser.error('--revs needs at least one revision argument')
    try:
        problems = commit_problems(arguments.revs) if arguments.revs is not None else configured_identity_problems()
    except subprocess.CalledProcessError as error:
        print((error.stderr or '').strip() or 'git failed', file=sys.stderr)
        return 2
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2
    for problem in problems:
        print(problem)
    if problems:
        print(REMEDY_REVS if arguments.revs is not None else REMEDY_NEXT)
        print(f'Commit identity check failed: {len(problems)} finding(s).')
        return 1
    if not arguments.quiet:
        print('Commit identity check passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
