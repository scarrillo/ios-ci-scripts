"""Synthetic version-editor fixtures; never edit real app manifests."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / 'bump-xcodegen-version.sh'


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='version fixture ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.yml = self.root / 'project.yml'
        self.yml.write_text('settings:\n  MARKETING_VERSION: "1.2.3"\n  CURRENT_PROJECT_VERSION: "7"\n')
        self.yml.chmod(0o640)

    def run_bump(self, *args):
        return subprocess.run(['bash', str(SCRIPT), str(self.root), *args], capture_output=True, text=True)

    def test_modes(self):
        for mode, expected in [('major', '2.0.0'), ('minor', '1.3.0'), ('patch', '1.2.4')]:
            with self.subTest(mode=mode):
                result = self.run_bump(mode, '--dry-run')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected+'\n')
                self.assertIn('[dry-run]', result.stderr)

    def test_decimal_and_duplicate_values(self):
        self.yml.write_text('MARKETING_VERSION: "01.08" # keep\nCURRENT_PROJECT_VERSION: 009\n'
                            'other:\n  MARKETING_VERSION: \'1.8.0\'\n  CURRENT_PROJECT_VERSION: "9"\n')
        result = self.run_bump('--build')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '1.8.1\n')
        data = self.yml.read_text()
        self.assertEqual(data.count('1.8.1'), 2)
        self.assertEqual(data.count('10'), 2)
        self.assertIn('# keep', data)
        self.assertEqual(self.yml.stat().st_mode & 0o777, 0o640)

    def test_invalid_is_unchanged(self):
        for data in ['MARKETING_VERSION: 1.2-beta\n',
                     'MARKETING_VERSION: 1.2\nMARKETING_VERSION: 1.3\n',
                     'MARKETING_VERSION: *version\n', 'OTHER: 1.2\n',
                     'MARKETING_VERSION: "1.2" junk\n']:
            with self.subTest(data=data):
                self.yml.write_text(data)
                result = self.run_bump()
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertEqual(self.yml.read_text(), data)

    def test_build_validation_before_write(self):
        self.yml.write_text('MARKETING_VERSION: 1.2\nCURRENT_PROJECT_VERSION: nope\n')
        before = self.yml.read_bytes()
        self.assertEqual(self.run_bump('--build').returncode, 2)
        self.assertEqual(self.yml.read_bytes(), before)
        self.assertEqual(self.run_bump().returncode, 0)

    def test_large_numbers_and_lookalikes(self):
        self.yml.write_text('MARKETING_VERSION: 1.2.999999999999999999999999\n# MARKETING_VERSION: 9.9\nTEXT: "1.2.999999999999999999999999"\n')
        result = self.run_bump()
        self.assertEqual(result.stdout, '1.2.1000000000000000000000000\n')
        self.assertIn('TEXT: "1.2.999999999999999999999999"', self.yml.read_text())

    def test_dry_run_no_writes(self):
        before = self.yml.stat()
        data = self.yml.read_bytes()
        entries = list(self.root.iterdir())
        self.assertEqual(self.run_bump('--dry-run', '--build').returncode, 0)
        self.assertEqual(self.yml.read_bytes(), data)
        self.assertEqual(self.yml.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(list(self.root.iterdir()), entries)

    def test_symlink_rejected(self):
        target = self.root / 'target.yml'
        self.yml.rename(target)
        self.yml.symlink_to(target)
        before = target.read_bytes()
        self.assertEqual(self.run_bump().returncode, 2)
        self.assertEqual(target.read_bytes(), before)
        self.assertTrue(self.yml.is_symlink())

    def test_arguments(self):
        for args in [('--unknown',), ('patch', 'minor'), ('extra',)]:
            self.assertEqual(self.run_bump(*args).returncode, 2)

    def embedded_main(self):
        code = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        code = code.rsplit('\ntry:\n    main()', 1)[0]
        namespace = {}
        exec(compile(code, str(SCRIPT), 'exec'), namespace)
        return namespace['main']

    def test_write_failure_preserves_original(self):
        before = self.yml.read_bytes()
        entries = list(self.root.iterdir())
        with mock.patch('sys.argv', [str(SCRIPT), str(self.root)]), \
             mock.patch('os.replace', side_effect=OSError('synthetic replace failure')):
            with self.assertRaises(OSError):
                self.embedded_main()()
        self.assertEqual(self.yml.read_bytes(), before)
        self.assertEqual(self.yml.stat().st_mode & 0o777, 0o640)
        self.assertEqual(list(self.root.iterdir()), entries)

    def test_dry_run_does_not_prepare_temporary(self):
        with mock.patch('sys.argv', [str(SCRIPT), str(self.root), '--dry-run']), \
             mock.patch('tempfile.NamedTemporaryFile', side_effect=AssertionError('unexpected write')), \
             mock.patch('builtins.print'):
            self.embedded_main()()

    def test_self_contained_copy(self):
        detached = self.root / 'unrelated'
        detached.mkdir()
        copied = detached / SCRIPT.name
        copied.write_bytes(SCRIPT.read_bytes())
        result = subprocess.run(['bash', str(copied), str(self.root), '--build'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '1.2.4\n')

    def test_crlf(self):
        self.yml.write_bytes(b'MARKETING_VERSION: "1.2"\r\nCURRENT_PROJECT_VERSION: "7"\r\n')
        self.assertEqual(self.run_bump('--build').returncode, 0)
        self.assertEqual(self.yml.read_bytes(), b'MARKETING_VERSION: "1.2.1"\r\nCURRENT_PROJECT_VERSION: "8"\r\n')

    def test_build_duplicates_invalid(self):
        for value in ('8', 'invalid'):
            self.yml.write_text('MARKETING_VERSION: 1.2\nCURRENT_PROJECT_VERSION: 7\nother:\n  CURRENT_PROJECT_VERSION: '+value+'\n')
            before = self.yml.read_bytes()
            self.assertEqual(self.run_bump('--build').returncode, 2)
            self.assertEqual(self.yml.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
