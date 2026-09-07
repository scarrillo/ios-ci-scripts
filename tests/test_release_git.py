"""Exercise real local Git with fictional projects; no network or user index."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'scripts/distribution/release-git.py'
spec = importlib.util.spec_from_file_location('release_git', MODULE)
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class GitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
            self.env.pop(key, None)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('config', 'tag.gpgsign', 'false')
        self.git('config', 'core.hooksPath', '/dev/null')
        self.path = self.root / 'sample/project.yml'
        self.path.parent.mkdir()
        self.write('1.0', '1')
        self.base = self.commit()
        self.repo = adapter.Repository(self.root)

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, env=self.env).decode().strip()

    def write(self, version, build):
        self.path.write_text('MARKETING_VERSION: "' + version +
                             '"\nCURRENT_PROJECT_VERSION: ' + build + '\n')

    def commit(self):
        self.git('add', '--', '.')
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def inspect(self, head, base=None):
        return self.repo.inspect(base or self.base, head, 'sample/project.yml', ['sample'])

    def test_changed_and_manual_and_worktree_ignored(self):
        self.assertEqual(self.inspect(self.base), 'skip')
        (self.path.parent / 'source.txt').write_text('changed')
        head = self.commit()
        self.assertEqual(self.inspect(head), 'bump')
        self.write('1.1', '2')
        head = self.commit()
        self.path.write_text('uncommitted invalid data')
        self.assertEqual(self.inspect(head), 'preserve')

    def test_current_base_not_historical_base(self):
        self.write('1.1', '2')
        advanced = self.commit()
        self.git('checkout', '-q', '--detach', self.base)
        self.write('1.0.1', '2')
        head = self.commit()
        with self.assertRaises(ValueError):
            self.inspect(head, base=advanced)

    def test_missing_build_and_symlink_rejected(self):
        self.path.write_text('MARKETING_VERSION: 1.1\n')
        with self.assertRaises(ValueError):
            self.inspect(self.commit())
        self.path.unlink()
        self.path.symlink_to('elsewhere')
        with self.assertRaises(ValueError):
            self.inspect(self.commit())

    def test_new_project_and_bad_identity(self):
        new = self.root / 'new/project.yml'
        new.parent.mkdir()
        new.write_text('MARKETING_VERSION: 1.0\nCURRENT_PROJECT_VERSION: 1\n')
        head = self.commit()
        self.assertEqual(self.repo.inspect(self.base, head, 'new/project.yml', ['new']), 'new')
        for sha in ('HEAD', '--help', '0' * 40):
            with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                self.repo.inspect(sha, head, 'new/project.yml', ['new'])
        with self.assertRaises(ValueError):
            self.repo.inspect(self.base, head, '../project.yml', ['new'])

    def test_annotated_and_future_tags(self):
        self.git('tag', '-a', 'sample/v1.0', '-m', 'fixture', self.base)
        self.write('2.0', '2')
        future = self.commit()
        self.git('tag', 'sample/v2.0', future)
        self.assertEqual(self.repo.baseline(self.base, 'sample/v'), 'sample/v1.0')
        self.assertEqual(self.repo.baseline(future, 'sample/v'), 'sample/v2.0')

    def test_metadata_duplicates_and_layout(self):
        self.assertEqual(adapter.metadata(
            "MARKETING_VERSION: '01.0' # note\nMARKETING_VERSION: 1.0.0\nCURRENT_PROJECT_VERSION: 01\n"),
            ('1.0.0', '1'))
        for text in ('MARKETING_VERSION: 1.0\nMARKETING_VERSION: 2.0\nCURRENT_PROJECT_VERSION: 1',
                     '{MARKETING_VERSION: 1.0}\nCURRENT_PROJECT_VERSION: 1',
                     'MARKETING_VERSION: *alias\nCURRENT_PROJECT_VERSION: 1'):
            with self.assertRaises(ValueError):
                adapter.metadata(text)


if __name__ == '__main__':
    unittest.main()
