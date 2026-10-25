#!/usr/bin/env python3
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

SCRIPTS = Path(__file__).resolve().parent
AUDIT = SCRIPTS / 'audit-public-tree.py'
STRIP = SCRIPTS / 'strip-png-metadata.py'


def chunk(kind, payload):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))


def png(*extra):
    header = chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0))
    pixels = chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00'))
    return b'\x89PNG\r\n\x1a\n' + header + b''.join(extra) + pixels + chunk(b'IEND', b'')


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.git('init', '-q')
        (self.root / 'README.md').write_text('# Sample\n\n![Popup](docs/popup.png)\n\nA plain - hyphen.\n')
        (self.root / 'docs').mkdir()
        (self.root / 'docs' / 'popup.png').write_bytes(png(chunk(b'sRGB', b'\x00')))
        (self.root / 'Tool.swift').write_text('let label = "5h - weekly"\n')
        self.git('add', '-A')

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        environment = dict(os.environ, GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                           GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.invalid')
        subprocess.run(['git', *arguments], cwd=self.root, env=environment, check=True, capture_output=True)

    def audit(self, *arguments):
        return subprocess.run([sys.executable, str(AUDIT), *arguments], cwd=self.root, capture_output=True, text=True)

    def add(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
        self.git('add', name)

    def assertFinding(self, expected, *arguments):
        result = self.audit(*arguments)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(expected, result.stdout)

    def test_clean_tree_passes_with_every_option(self):
        self.git('commit', '-qm', 'initial')
        result = self.audit('--require-clean', '--public-docs', '--forbid', 'FORBIDDEN-TERM',
                            '--require-file', 'README.md', '--require-file', 'docs/popup.png')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('Audit passed.', result.stdout)

    def test_credential_shapes_are_reported(self):
        samples = {
            'Anthropic API key': 'sk' + '-ant-' + 'a' * 24,
            'GitHub token': 'gh' + 'p_' + 'b' * 36,
            'AWS access key': 'AK' + 'IA' + 'C' * 16,
            'private key': '-----BEGIN RSA PRIV' + 'ATE KEY-----',
            'JSON web token': 'ey' + 'J' + 'd' * 12 + '.' + 'e' * 12 + '.sig',
            'bearer token': 'Authorization: Bear' + 'er ' + 'f' * 32,
        }
        for label, secret in samples.items():
            with self.subTest(label=label):
                self.add('config.txt', f'value = {secret}\n')
                self.assertFinding(f'config.txt:1: possible {label}')

    def test_home_path_is_reported(self):
        self.add('notes.txt', 'Built in /' + 'Users/someone/project\n')
        self.assertFinding('notes.txt:1: absolute home-directory path')

    def test_long_dash_in_authored_text_is_reported(self):
        self.add('Guide.md', 'Remaining ' + chr(0x2014) + ' weekly\n')
        self.assertFinding('Guide.md:1: long Unicode dash')

    def test_png_metadata_is_reported_and_stripping_keeps_pixels(self):
        image = png(chunk(b'iTXt', b'XML:com.adobe.xmp\x00\x00\x00\x00\x00<x:xmpmeta/>'), chunk(b'eXIf', b'MM\x00*'))
        self.add('docs/popup.png', image)
        self.assertFinding('docs/popup.png: metadata chunk iTXt')
        subprocess.run([sys.executable, str(STRIP), str(self.root / 'docs' / 'popup.png')], check=True, capture_output=True)
        stripped = (self.root / 'docs' / 'popup.png').read_bytes()
        self.assertNotIn(b'iTXt', stripped)
        self.assertNotIn(b'eXIf', stripped)
        self.assertIn(chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00')), stripped)
        self.git('add', 'docs/popup.png')
        self.assertEqual(self.audit().returncode, 0)

    def test_missing_readme_image_is_reported(self):
        self.git('rm', '-q', '--cached', 'docs/popup.png')
        self.assertFinding('image target docs/popup.png is not a tracked file')

    def test_forbidden_term_and_private_log_phrase_are_reported(self):
        self.add('AGENTS.md', 'Ask FORBIDDEN-TERM first.\nThe human decides.\n')
        self.assertFinding("AGENTS.md:1: forbidden term 'FORBIDDEN-TERM'", '--forbid', 'FORBIDDEN-TERM')
        self.assertFinding('AGENTS.md:2: private-log phrasing', '--public-docs')

    def test_missing_required_file_and_dirty_worktree_are_reported(self):
        self.assertFinding('LICENSE: required file is not tracked', '--require-file', 'LICENSE')
        self.git('commit', '-qm', 'initial')
        (self.root / 'untracked.txt').write_text('new\n')
        self.assertFinding('worktree is not clean', '--require-clean')


if __name__ == '__main__':
    unittest.main()
