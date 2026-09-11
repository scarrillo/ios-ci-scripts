"""Workflow CLI tests with local bare remotes; no GitHub or network access."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TESTS = Path(__file__).parent
spec = importlib.util.spec_from_file_location('git_tests', TESTS / 'test_release_git.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
CLI = fixtures.MODULE.with_name('release_prep.py')


class WorkflowTests(unittest.TestCase):
    git = fixtures.GitTests.git
    write = fixtures.GitTests.write
    commit = fixtures.GitTests.commit

    def setUp(self):
        fixtures.GitTests.setUp(self)
        remote_dir = tempfile.TemporaryDirectory()
        self.addCleanup(remote_dir.cleanup)
        self.remote = Path(remote_dir.name) / 'remote.git'
        self.git('init', '--bare', '-q', str(self.remote))
        self.git('remote', 'add', 'origin', str(self.remote))
        self.git('push', '-q', 'origin', self.base + ':refs/heads/topic')

    def run_cli(self, *args):
        return subprocess.run([sys.executable, '-I', '-B', str(CLI), '--repo', str(self.root), *args],
                              env=self.env, capture_output=True, text=True)

    def check_head(self, sha):
        return self.run_cli('remote-head', '--ref', 'refs/heads/topic', '--expected', sha)

    def test_head_move_delete_and_lookup_failure(self):
        self.assertEqual(self.check_head(self.base).returncode, 0)
        self.write('1.1', '2')
        head = self.commit()
        self.git('push', '-q', 'origin', head + ':refs/heads/topic')
        self.assertEqual(self.check_head(self.base).returncode, 2)
        self.assertEqual(self.check_head(head).returncode, 0)
        self.git('push', '-q', 'origin', ':refs/heads/topic')
        result = self.check_head(head)
        self.assertEqual(result.returncode, 2)
        self.assertIn('PR head moved or disappeared', result.stderr)
        self.git('remote', 'set-url', 'origin', str(self.root / 'missing'))
        result = self.check_head(head)
        self.assertEqual(result.returncode, 2)
        self.assertIn('Git operation failed', result.stderr)

    def test_inspection_cli_and_readonly_fork(self):
        (self.path.parent / 'source.txt').write_text('change')
        head = self.commit()
        args = ('inspect', '--base', self.base, '--head', head,
                '--project', 'sample/project.yml', '--scope', 'sample')
        result = self.run_cli(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'bump\n')
        self.assertEqual(self.run_cli(*args, '--read-only').returncode, 2)
        self.write('1.1', '2')
        prepared = self.commit()
        result = self.run_cli('inspect', '--base', self.base, '--head', prepared,
                              '--project', 'sample/project.yml', '--scope', 'sample', '--read-only')
        self.assertEqual(result.stdout, 'preserve\n')

    def test_invalid_ref_is_rejected(self):
        for ref in ('--help', 'topic', 'refs/heads/*'):
            self.assertNotEqual(self.run_cli('remote-head', '--ref=' + ref,
                                            '--expected', self.base).returncode, 0)


if __name__ == '__main__':
    unittest.main()
