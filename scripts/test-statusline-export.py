#!/usr/bin/env python3
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


class ExportTests(unittest.TestCase):
    def test_export_is_sanitized_private_and_missing_windows_do_not_overwrite_it(self):
        script = Path(__file__).with_name('capture-claude-statusline.py')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            account = root / 'account.json'
            account.write_text(json.dumps({'oauthAccount': {'organizationUuid': 'test-org', 'emailAddress': 'excluded'}}))
            cache = root / 'usage.json'
            env = dict(os.environ, QUOTABAR_CLAUDE_ACCOUNT_FILE=str(account), QUOTABAR_CLAUDE_CACHE=str(cache))
            payload = {'rate_limits': {'five_hour': {'used_percentage': 18, 'resets_at': 1792761243}},
                       'irrelevant_secret': 'MUST_NOT_BE_SAVED', 'transcript_path': 'MUST_NOT_BE_SAVED'}
            subprocess.run([sys.executable, str(script)], input=json.dumps(payload), text=True, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            contents = cache.read_text()
            saved = json.loads(contents)
            self.assertEqual(set(saved), {'organizationID', 'capturedAt', 'rate_limits'})
            self.assertEqual(saved['rate_limits']['five_hour']['used_percentage'], 18)
            self.assertNotIn('MUST_NOT_BE_SAVED', contents)
            self.assertNotIn('excluded', contents)
            self.assertEqual(stat.S_IMODE(cache.stat().st_mode), 0o600)
            subprocess.run([sys.executable, str(script)], input='{"rate_limits":{}}', text=True, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            self.assertEqual(cache.read_text(), contents)


if __name__ == '__main__':
    unittest.main()
