"""Execute the workflow prep shell against a local bare remote, not GitHub."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

spec = importlib.util.spec_from_file_location('git_tests', Path(__file__).with_name('test_release_git.py'))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
ROOT = fixtures.MODULE.parents[2]
WORKFLOW = ROOT / 'workflows/release-prep.yml'


class PrepTests(unittest.TestCase):
    git = fixtures.GitTests.git
    write = fixtures.GitTests.write
    commit = fixtures.GitTests.commit

    def setUp(self):
        fixtures.GitTests.setUp(self)
        (self.root / 'apps').mkdir()
        (self.root / 'sample').rename(self.root / 'apps/sample')
        self.path = self.root / 'apps/sample/project.yml'
        self.base = self.commit()
        remote = tempfile.TemporaryDirectory()
        self.addCleanup(remote.cleanup)
        self.remote = Path(remote.name) / 'remote.git'
        self.git('init', '--bare', '-q', str(self.remote))
        self.git('remote', 'add', 'origin', str(self.remote))
        self.git('push', '-q', 'origin', self.base + ':refs/heads/topic')
        self.output = Path(remote.name) / 'outputs'
        jobs = yaml.safe_load(WORKFLOW.read_text())['jobs']
        steps = next(iter(jobs.values()))['steps']
        self.script = next(step['run'] for step in steps if step.get('id') == 'prep')
        self.prefix = ''

    def prepare(self, head, **extra):
        env = dict(self.env, HEAD_SHA=head, HEAD_REF='topic', SAME_REPO='true',
                   PR_NUMBER='1', PROJECT_DIR='apps/sample', RELEASE_BASE_SHA=self.base,
                   RELEASE_TOOLS=str(fixtures.MODULE.parent), GITHUB_OUTPUT=str(self.output))
        env.update(extra)
        return subprocess.run(['bash', '-euo', 'pipefail', '-c', self.prefix + self.script],
                              cwd=self.root, env=env, capture_output=True, text=True)

    def changed_head(self):
        (self.path.parent / 'source.txt').write_text('change')
        head = self.commit()
        self.git('push', '-q', 'origin', head + ':refs/heads/topic')
        return head

    def test_bump_and_retry(self):
        head = self.changed_head()
        result = self.prepare(head)
        self.assertEqual(result.returncode, 0, result.stderr)
        prepared = self.git('rev-parse', 'HEAD')
        self.assertNotEqual(head, prepared)
        self.assertEqual(fixtures.adapter.metadata(self.path.read_text()), ('1.0.1', '2'))
        self.assertIn('sha=' + prepared, self.output.read_text())
        self.assertEqual(self.prepare(prepared).returncode, 0)
        self.assertEqual(self.git('rev-parse', 'HEAD'), prepared)

    def test_fork_requires_authored_bump_without_writes(self):
        head = self.changed_head()
        self.git('push', '-q', 'origin', head + ':refs/pull/1/head')
        self.assertNotEqual(self.prepare(head, SAME_REPO='false').returncode, 0)
        self.write('1.1', '2')
        authored = self.commit()
        self.git('push', '-q', 'origin', authored + ':refs/pull/1/head')
        result = self.prepare(authored, SAME_REPO='false')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git('rev-parse', 'HEAD'), authored)
        self.assertTrue(self.git('ls-remote', 'origin', 'refs/heads/topic').startswith(head))

    def test_stale_head_never_prepares(self):
        head = self.changed_head()
        before = self.path.read_bytes()
        self.git('push', '-q', 'origin', ':refs/heads/topic')
        self.assertNotEqual(self.prepare(head).returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)

    def test_invalid_manual_version_fails(self):
        self.write('0.9', '3')
        head = self.commit()
        self.git('push', '-q', 'origin', head + ':refs/heads/topic')
        self.assertNotEqual(self.prepare(head).returncode, 0)
        self.assertEqual(self.git('rev-parse', 'HEAD'), head)

    def test_concurrent_push_is_not_overwritten(self):
        head = self.changed_head()
        tree = self.git('rev-parse', 'HEAD^{tree}')
        racing = self.git('commit-tree', tree, '-p', head, '-m', 'concurrent work')
        self.git('push', '-q', 'origin', racing + ':refs/heads/other')
        self.prefix = ('git() { if [ "$1" = push ]; then command git --git-dir="$RACE_REMOTE" '
                       'update-ref refs/heads/topic "$RACE_SHA"; fi; command git "$@"; }\n')
        result = self.prepare(head, RACE_REMOTE=str(self.remote), RACE_SHA=racing)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.git('ls-remote', 'origin', 'refs/heads/topic').startswith(racing))
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
