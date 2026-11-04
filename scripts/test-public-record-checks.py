#!/usr/bin/env python3
"""Tests for check-public-text.py and check-commit-identity.py on synthetic repositories."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
TEXT = SCRIPTS / 'check-public-text.py'
IDENTITY = SCRIPTS / 'check-commit-identity.py'
# Addresses and paths are assembled from fragments so the tree audit never matches this file.
NOREPLY = '1+test' + '@' + 'users.noreply.github.com'
PERSONAL = 'jane.doe' + '@' + 'gmail.com'
HOME = '/' + 'Users/jane/Projects'


class Repository(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith('GIT_') and key != 'QUOTABAR_PRIVATE_TERMS'}
        self.environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', NOREPLY)

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments, **environment):
        subprocess.run(['git', *arguments], cwd=self.root, env=dict(self.environment, **environment),
                       check=True, capture_output=True)

    def run_script(self, script, *arguments, text=''):
        return subprocess.run([sys.executable, str(script), *arguments], cwd=self.root, env=self.environment,
                              input=text, capture_output=True, text=True)


class PublicTextTests(Repository):
    def test_public_addresses_and_runner_paths_pass(self):
        text = '\n'.join([
            'Co-Authored-By: Claude <noreply' + '@' + 'anthropic.com>',
            'Signed-off-by: dependabot[bot] <support' + '@' + 'github.com>',
            'By ' + NOREPLY + ' and 49699333+dependabot[bot]' + '@' + 'users.noreply.github.com',
            'uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
            'git clone git' + '@' + 'github.com:owner/repo.git',
            'CI: /' + 'Users/runner/work/quotabar/quotabar/Sources/App.swift:12:5',
        ])
        result = self.run_script(TEXT, '-', text=text)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_private_details_fail_without_echoing_them(self):
        result = self.run_script(TEXT, '--label', 'draft', '-', text=f'Ask {PERSONAL}\nBuilt in {HOME}\n')
        self.assertEqual(result.returncode, 1)
        self.assertIn('draft:1: email address that is not a public noreply address', result.stdout)
        self.assertIn('draft:2: absolute home-directory path', result.stdout)
        self.assertNotIn('jane', result.stdout)

    def test_added_terms_live_hashed_in_the_git_directory(self):
        added = self.run_script(TEXT, '--add-term', text='HiddenTool\n')
        self.assertEqual(added.returncode, 0, added.stderr)
        terms = self.root / '.git' / 'quotabar-private-terms.txt'
        self.assertTrue(terms.is_file())
        self.assertNotIn('hiddentool', terms.read_text().lower())
        for line in ['Reviewed with HiddenTool.', 'Reviewed with useHiddentool.']:
            with self.subTest(line=line):
                result = self.run_script(TEXT, '-', text=line + '\n')
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn('private term (hash match)', result.stdout)
        self.assertEqual(self.run_script(TEXT, '--private-terms', 'missing.txt', '-', text='x\n').returncode, 2)

    def test_revs_checks_each_commit_name_and_message(self):
        self.git('commit', '-q', '--allow-empty', '-m', 'feat: clean')
        self.git('commit', '-q', '--allow-empty', '-m', f'fix: notes in {HOME}')
        result = self.run_script(TEXT, '--revs', 'HEAD')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertRegex(result.stdout, r'commit [0-9a-f]{12}:\d+: absolute home-directory path')
        self.git('commit', '-q', '--allow-empty', '-m', 'chore: named', GIT_AUTHOR_NAME=PERSONAL)
        result = self.run_script(TEXT, '--revs', 'HEAD~1..HEAD')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(':1: email address that is not a public noreply address', result.stdout)
        self.assertEqual(self.run_script(TEXT, '--revs').returncode, 2)


class CommitIdentityTests(Repository):
    def test_noreply_identity_and_history_pass(self):
        self.git('commit', '-q', '--allow-empty', '-m', 'feat: a')
        self.assertEqual(self.run_script(IDENTITY).returncode, 0)
        self.assertEqual(self.run_script(IDENTITY, '--revs', 'HEAD').returncode, 0)

    def test_personal_addresses_fail_without_echoing_them(self):
        self.git('commit', '-q', '--allow-empty', '-m', 'feat: a', GIT_AUTHOR_EMAIL=PERSONAL)
        result = self.run_script(IDENTITY, '--revs', 'HEAD')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('author email is not a GitHub noreply address', result.stdout)
        self.assertNotIn('committer email', result.stdout)
        self.assertNotIn('jane', result.stdout)
        self.git('config', 'user.email', PERSONAL)
        self.assertEqual(self.run_script(IDENTITY).returncode, 1)

    def test_usage_and_git_errors_exit_2(self):
        self.assertEqual(self.run_script(IDENTITY, '--revs').returncode, 2)
        self.assertEqual(self.run_script(IDENTITY, '--revs', 'no-such-revision').returncode, 2)


if __name__ == '__main__':
    unittest.main()
