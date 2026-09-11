"""Prepare release decisions and verify Git heads; no writes, tags, or dispatches.

Load this file and release_yaml.py from one trusted revision. The workflow owns
mutation; this CLI only reads project blobs and branch identities.
"""
import argparse
import importlib.util
from pathlib import Path
import re
import subprocess
import sys


yaml_spec = importlib.util.spec_from_file_location(
    'release_yaml', Path(__file__).with_name('release_yaml.py'))
release_yaml = importlib.util.module_from_spec(yaml_spec)
yaml_spec.loader.exec_module(release_yaml)
metadata = release_yaml.metadata


def version(value):
    """Normalize a literal decimal X.Y or X.Y.Z (not a YAML token)."""
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', value):
        raise ValueError('version must be decimal X.Y or X.Y.Z')
    parts = tuple(int(part, 10) for part in value.split('.'))
    return parts if len(parts) == 3 else parts + (0,)


def build(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]+', value):
        raise ValueError('build must be a decimal integer')
    return int(value, 10)


def preparation(head_version, head_build, *, base=None, changed=True, writable=True):
    """Return skip/new/preserve/bump; invalid or unsafe changes raise ValueError.

    base is None only for a genuinely new app, otherwise a (version, build)
    pair from the current base tip. A read-only/fork consumer must author its
    own bump. Mixed manual edits are rejected instead of silently overwritten.
    """
    if not changed:
        return 'skip'
    head = (version(head_version), build(head_build))
    if base is None:
        return 'new'
    previous = (version(base[0]), build(base[1]))
    if head == previous:
        if not writable:
            raise ValueError('read-only preparation requires a contributor-authored bump')
        return 'bump'
    if head[0] > previous[0] and head[1] > previous[1]:
        return 'preserve'
    raise ValueError('changed app must increase both version and build')


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
        return preparation(*current, base=self.project(base, project),
                                 writable=writable)


def remote_head(repo, ref, expected):
    repo.commit(expected)
    if not ref.startswith(('refs/heads/', 'refs/pull/')):
        raise ValueError('expected a full branch or pull-request head ref')
    repo.git('check-ref-format', ref)
    rows = repo.git('ls-remote', 'origin', ref).decode().splitlines()
    if rows != [expected + '\t' + ref]:
        raise ValueError('PR head moved or disappeared; retry on the current head')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='.')
    commands = parser.add_subparsers(dest='command', required=True)
    inspect = commands.add_parser('inspect')
    inspect.add_argument('--base', required=True)
    inspect.add_argument('--head', required=True)
    inspect.add_argument('--project', required=True)
    inspect.add_argument('--scope', action='append', required=True)
    inspect.add_argument('--read-only', action='store_true')
    check = commands.add_parser('remote-head')
    check.add_argument('--ref', required=True)
    check.add_argument('--expected', required=True)
    args = parser.parse_args(argv)
    repo = Repository(args.repo)
    if args.command == 'remote-head':
        remote_head(repo, args.ref, args.expected)
    else:
        print(repo.inspect(args.base, args.head, args.project, args.scope,
                           writable=not args.read_only))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # Git stderr may contain remote configuration; report no credentials.
        message = 'Git operation failed; retry after checking repository access' if isinstance(
            error, subprocess.CalledProcessError) else str(error)
        print('release validation failed: ' + message, file=sys.stderr)
        sys.exit(2)
