"""Read-only Git adapter. Load this and release-state.py from one trusted revision.

No checkout, fetch, push, tags, API calls, or PR-provided code execution.
Metadata support is deliberately bounded, not a general YAML interpretation.
"""
import importlib.util
from pathlib import Path
import re
import subprocess

spec = importlib.util.spec_from_file_location(
    'release_state', Path(__file__).with_name('release-state.py'))
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


def metadata(text):
    result = []
    for key, parse in (('MARKETING_VERSION', state.version),
                       ('CURRENT_PROJECT_VERSION', state.build)):
        values = []
        for line in text.splitlines():
            if line.lstrip().startswith('#'):
                continue
            if not re.search(r"""(?:^|[\s{,])['"]?""" + key + r"""['"]?\s*:""", line):
                continue
            match = re.fullmatch(
                r'[ \t]*' + key + r""":[ \t]*(?:"([0-9.]+)"|'([0-9.]+)'|([0-9.]+))(?:[ \t]+#.*|[ \t]*)""",
                line)
            if match is None:
                raise ValueError('unsupported ' + key + ' declaration')
            value = next(value for value in match.groups() if value is not None)
            values.append(parse(value))
        if not values or any(value != values[0] for value in values):
            raise ValueError('missing or inconsistent ' + key)
        result.append('.'.join(map(str, values[0])) if isinstance(values[0], tuple)
                      else str(values[0]))
    return tuple(result)


class Repository:
    def __init__(self, directory):
        self.directory = directory

    def git(self, *args):
        return subprocess.run(['git', '--no-replace-objects', '-C', str(self.directory),
                               *args], check=True, capture_output=True).stdout

    def commit(self, sha):
        if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', sha):
            raise ValueError('expected a full immutable commit ID')
        if self.git('cat-file', '-t', sha).strip() != b'commit':
            raise ValueError('expected a commit object')
        return sha

    @staticmethod
    def path(path):
        if not isinstance(path, str) or any(
                part in ('', '.', '..') for part in path.split('/')) or '\0' in path:
            raise ValueError('expected a repository-relative literal path')
        return path

    def project(self, sha, path):
        """None means absent; Git failures and non-regular entries are errors."""
        self.path(path)
        parts = path.split('/')
        for index in range(1, len(parts) + 1):
            prefix = '/'.join(parts[:index])
            entry = self.git('ls-tree', '-z', sha, '--', prefix)
            if not entry:
                return None
            info, actual = entry.rstrip(b'\0').split(b'\t', 1)
            mode, kind, oid = info.split()
            if actual.decode() != prefix:
                raise ValueError('unexpected tree entry')
            if index < len(parts):
                if mode != b'040000':
                    raise ValueError('project parent must be a tree')
            elif mode not in (b'100644', b'100755') or kind != b'blob':
                raise ValueError('project must be a regular blob')
        return metadata(self.git('cat-file', 'blob', oid.decode()).decode('utf-8'))

    def inspect(self, base, head, project, scopes, *, writable=True):
        """Attribute changes from merge-base, validate numbers against base tip."""
        base, head = self.commit(base), self.commit(head)
        project = self.path(project)
        scopes = [self.path(scope) for scope in scopes]
        if not scopes:
            raise ValueError('at least one change scope is required')
        fork = self.git('merge-base', '--all', base, head).decode().splitlines()
        if len(fork) != 1:
            raise ValueError('expected a unique merge base')
        changed = bool(self.git('diff', '--no-ext-diff', '--no-textconv',
                                '--name-only', '-z', fork[0], head, '--',
                                *[':(literal)' + path for path in [project, *scopes]]))
        if not changed:
            return 'skip'
        current = self.project(head, project)
        if current is None:
            raise ValueError('changed project missing at head; deletion requires explicit policy')
        return state.preparation(*current, base=self.project(base, project),
                                 writable=writable)

    def baseline(self, merge, prefix):
        merge = self.commit(merge)
        if not prefix or any(c in prefix for c in '*?[]\0\n'):
            raise ValueError('expected a literal nonempty tag prefix')
        candidates, reachable = [], []
        for name in self.git('tag', '--list').decode().splitlines():
            if not name.startswith(prefix):
                continue
            commit = self.git('rev-parse', '--verify', 'refs/tags/' + name + '^{commit}').decode().strip()
            ancestor = subprocess.run(
                ['git', '--no-replace-objects', '-C', str(self.directory),
                 'merge-base', '--is-ancestor', commit, merge], capture_output=True)
            if ancestor.returncode not in (0, 1):
                raise RuntimeError('tag ancestry lookup failed')
            candidates.append((name, name[len(prefix):], commit))
            if ancestor.returncode == 0:
                reachable.append(commit)
        return state.baseline(candidates, reachable)
