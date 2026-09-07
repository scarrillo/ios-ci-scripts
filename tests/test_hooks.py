"""Synthetic consumers; never run a hook against this checkout's index."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'consumer'
        self.repo.mkdir()
        self.bin = Path(self.temp.name) / 'bin'
        self.bin.mkdir()
        self.log = Path(self.temp.name) / 'calls'
        self.developer = (subprocess.check_output(['xcode-select', '-p']).decode().strip()
                          if sys.platform == 'darwin' else '/explicit/toolchain')
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        CALLS=str(self.log), GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_NOSYSTEM='1', DEVELOPER_DIR=self.developer)
        for key in list(self.env):
            if key.startswith('GIT_') and key not in ('GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM'):
                del self.env[key]
        self.git('init', '-q')
        self.git('config', 'user.name', 'Example Contributor')
        self.git('config', 'user.email', 'contributor@example.org')
        self.git('config', 'core.hooksPath', '/dev/null')
        self.git('config', 'commit.gpgsign', 'false')
        self.git('commit', '--allow-empty', '-qm', 'initial')
        stub = '''#!/usr/bin/env python3
import json, os, pathlib, sys
tool = pathlib.Path(sys.argv[0]).name
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps([tool, sys.argv[1:], os.environ.get('DEVELOPER_DIR')]) + '\\n')
if tool == 'jq':
    if os.environ.get('JQ_EXIT'):
        sys.exit(int(os.environ['JQ_EXIT']))
    print(json.load(sys.stdin).get('tool_input', {}).get('command', ''))
elif tool == 'swift':
    if '--version' in sys.argv:
        sys.exit(int(os.environ.get('VERSION_EXIT', '0')))
    if os.environ.get('FORMAT_EXIT'):
        sys.exit(int(os.environ['FORMAT_EXIT']))
    p = pathlib.Path(sys.argv[-1])
    p.write_bytes(p.read_bytes().replace(b'unformatted', b'formatted'))
elif tool == 'swiftlint':
    print('warning: synthetic warning')
    sys.exit(int(os.environ.get('LINT_EXIT', '0')))
'''
        for tool in ('swift', 'swiftlint', 'jq'):
            path = self.bin / tool
            path.write_text(stub)
            path.chmod(0o755)

    def git(self, *args, check=True):
        return subprocess.run(['git', *args], cwd=self.repo, env=self.env,
                              capture_output=True, check=check)

    def stage(self, name, data=b'unformatted\n'):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.git('add', '--', ':(literal)' + name)
        return path

    def hook(self, claude=False, command='git commit -m example', **env):
        return subprocess.run(['bash', str(ROOT / 'hooks' / (
            'pre-commit-lint.sh' if claude else 'pre-commit.sh'))],
            cwd=self.repo, env={**self.env, 'CLAUDE_PROJECT_DIR': str(self.repo), **env},
            input=json.dumps({'tool_input': {'command': command}}).encode(), capture_output=True)

    def calls(self, tool):
        return [row[1] for row in map(json.loads, self.log.read_text().splitlines())
                if row[0] == tool] if self.log.exists() else []

    def test_no_swift_and_noncommit_skip_tools(self):
        self.assertEqual(self.hook().returncode, 0)
        self.stage('a.swift')
        self.assertEqual(self.hook(claude=True, command='git status').returncode, 0)
        self.assertFalse(self.calls('swift'))

    def test_partial_stage_preflight_preserves_all_files(self):
        (self.repo / '.swift-format').write_text('{}')
        first = self.stage('a.swift')
        second = self.stage('z.swift')
        second.write_bytes(b'unstaged\n')
        before = self.git('diff', '--cached', '--binary').stdout
        for claude in (False, True):
            result = self.hook(claude=claude)
            self.assertEqual(result.returncode, 2 if claude else 1, result.stderr)
            self.assertEqual(before, self.git('diff', '--cached', '--binary').stdout)
            self.assertEqual(first.read_bytes(), b'unformatted\n')
            self.assertEqual(second.read_bytes(), b'unstaged\n')
        self.assertFalse(self.calls('swift'))

    def test_format_literal_names_and_rename(self):
        names = ['space name.swift', 'tab\tname.swift', 'line\nname.swift',
                 '日本.swift', '-option.swift', ':(glob)*.swift', '[ab].swift']
        self.stage('old.swift')
        self.git('commit', '-qm', 'old')
        self.git('mv', 'old.swift', 'renamed.swift')
        for name in names:
            self.stage(name)
        (self.repo / '.swift-format').write_text('{}')
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = set(names + ['renamed.swift'])
        formats = [args for args in self.calls('swift') if '--version' not in args]
        self.assertEqual({args[-1] for args in formats}, expected)
        self.assertTrue(all(args[-2] == '--' for args in formats))
        lint = self.calls('swiftlint')[-1]
        self.assertEqual(set(lint[lint.index('--') + 1:]), expected)
        for name in expected:
            self.assertEqual(self.git('show', ':' + name).stdout, b'formatted\n')
        self.assertEqual(self.git('diff', '--exit-code').returncode, 0)

    def test_optional_format_and_config_precedence(self):
        self.stage('a.swift')
        (self.repo / 'ci_scripts').mkdir()
        (self.repo / 'ci_scripts/.swiftlint.yml').write_text('rules: []')
        self.assertEqual(self.hook().returncode, 0)
        self.assertIn('ci_scripts/.swiftlint.yml', self.calls('swiftlint')[-1])
        (self.repo / '.swiftlint.local.yml').write_text('rules: []')
        self.assertEqual(self.hook().returncode, 0)
        self.assertIn('.swiftlint.local.yml', self.calls('swiftlint')[-1])
        self.assertTrue(all('--version' in args for args in self.calls('swift')))

    def test_missing_parent_fails_before_formatting(self):
        self.stage('a.swift')
        (self.repo / '.swiftlint.local.yml').write_text('parent_config: ci_scripts/.swiftlint.yml\n')
        result = self.hook()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Missing ci_scripts', result.stderr)
        self.assertFalse(self.calls('swift'))

    def test_tool_errors_block_both_adapters(self):
        self.stage('a.swift')
        (self.repo / '.swift-format').write_text('{}')
        for setting in ('VERSION_EXIT', 'FORMAT_EXIT', 'LINT_EXIT'):
            for claude in (False, True):
                result = self.hook(claude=claude, **{setting: '7'})
                self.assertNotEqual(result.returncode, 0, (setting, result.stderr))
                if claude:
                    self.assertEqual(result.returncode, 2)

    def test_formatter_failure_does_not_stage(self):
        self.stage('a.swift')
        (self.repo / '.swift-format').write_text('{}')
        before = self.git('diff', '--cached', '--binary').stdout
        self.assertNotEqual(self.hook(FORMAT_EXIT='7').returncode, 0)
        self.assertEqual(self.git('diff', '--cached', '--binary').stdout, before)
        self.assertFalse(self.calls('swiftlint'))

    def test_missing_linter_blocks_before_formatting(self):
        self.stage('a.swift')
        (self.repo / '.swift-format').write_text('{}')
        shell_env = Path(self.temp.name) / 'shell-env'
        shell_env.write_text('command() {\n'
                             '  if [[ "$1" == -v && "$2" == swiftlint ]]; then return 1; fi\n'
                             '  builtin command "$@"\n}\n')
        result = self.hook(BASH_ENV=str(shell_env))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'swiftlint is missing', result.stderr)
        self.assertFalse(self.calls('swiftlint'))
        self.assertEqual((self.repo / 'a.swift').read_bytes(), b'unformatted\n')

    def test_unrelated_unstaged_file_is_unchanged(self):
        self.stage('staged.swift')
        unrelated = self.repo / 'unrelated.swift'
        unrelated.write_bytes(b'leave unformatted\n')
        (self.repo / '.swift-format').write_text('{}')
        self.assertEqual(self.hook().returncode, 0)
        self.assertEqual(unrelated.read_bytes(), b'leave unformatted\n')
        self.assertEqual(self.git('ls-files', '--', 'unrelated.swift').stdout, b'')

    def test_adapter_input_and_directory_errors_block(self):
        self.stage('a.swift')
        for directory in ('', '/no/such/project'):
            result = self.hook(claude=True, CLAUDE_PROJECT_DIR=directory)
            self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.hook(claude=True, JQ_EXIT='127').returncode, 2)
        result = subprocess.run(['bash', str(ROOT / 'hooks/pre-commit-lint.sh')],
                                cwd=self.repo, env=self.env, input=b'{invalid', capture_output=True)
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_git_selection_error_blocks(self):
        result = self.hook(GIT_INDEX_FILE=str(self.repo / 'missing-dir/index'),
                           GIT_DIR=str(self.repo / 'not-a-repo'))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls('swift'))

    def test_linked_worktree(self):
        original = self.repo
        linked = Path(self.temp.name) / 'linked'
        self.git('worktree', 'add', '-qb', 'linked', str(linked))
        self.repo = linked
        self.stage('linked.swift')
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls('swiftlint')[-1], ['lint', '--', 'linked.swift'])
        self.repo = original

    def test_symlink_refused(self):
        self.stage('target.txt')
        (self.repo / 'link.swift').symlink_to('target.txt')
        self.git('add', 'link.swift')
        self.assertNotEqual(self.hook().returncode, 0)
        self.assertFalse(self.calls('swift'))

    def test_merge_skips_imported_content_checks_resolution(self):
        self.stage('shared.swift', b'base\n')
        self.git('commit', '-qm', 'base')
        base = self.git('rev-parse', 'HEAD').stdout.strip().decode()
        self.git('checkout', '-qb', 'other')
        self.stage('shared.swift', b'other\n')
        self.stage('imported.swift')
        self.git('commit', '-qm', 'other')
        self.git('checkout', '-qb', 'current', base)
        self.stage('shared.swift', b'current\n')
        self.git('commit', '-qm', 'current')
        self.assertNotEqual(self.git('merge', '--no-commit', 'other', check=False).returncode, 0)
        self.stage('shared.swift', b'resolved\n')
        (self.repo / '.swift-format').write_text('{}')
        result = self.hook(claude=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls('swiftlint')[-1], ['lint', '--', 'shared.swift'])
        self.assertEqual((self.repo / 'imported.swift').read_bytes(), b'unformatted\n')

    def test_developer_dir_preserved(self):
        self.stage('a.swift')
        self.assertEqual(self.hook().returncode, 0)
        for row in map(json.loads, self.log.read_text().splitlines()):
            self.assertEqual(row[2], self.developer)


if __name__ == '__main__':
    unittest.main()
