#!/usr/bin/env bash
# Bump project.yml: <app-dir> [major|minor|patch] [--build] [--dry-run].
# Self-contained portable CLI; requires Python 3 (stdlib only).
# Supports decimal X.Y / X.Y.Z and integer build scalars, plain or single/double
# quoted, with optional trailing comments. Repeated declarations must agree.
# This is a bounded line-oriented XcodeGen editor, not a general YAML parser.
# stdout: new marketing version only; diagnostics: stderr; invalid input: exit 2.
# No Git operations. Dry-run performs no writes. Real updates replace atomically.
set -euo pipefail
exec python3 - "$@" <<'PY'
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


def arguments(args):
    app = None
    mode = None
    build = dry = False
    for arg in args:
        if arg in ('major', 'minor', 'patch'):
            if mode is not None:
                raise ValueError('specify only one bump mode')
            mode = arg
        elif arg == '--build':
            build = True
        elif arg == '--dry-run':
            dry = True
        elif arg.startswith('-'):
            raise ValueError('unknown flag: '+arg)
        elif app is None:
            app = arg
        else:
            raise ValueError('unexpected argument: '+arg)
    if app is None:
        raise ValueError('usage: bump-xcodegen-version.sh <app-dir> [major|minor|patch] [--build] [--dry-run]')
    return app, mode or 'patch', build, dry


def declarations(text, key, marketing):
    # No aliases, tags, expressions, flow mappings, quoted keys or block scalars.
    pattern = re.compile(r'(?m)^(?P<prefix>[ \t]*'+key+r':[ \t]*)(?P<value>[^\r\n]*)(?P<end>\r?$)')
    scalar = re.compile(r"""(?P<token>"[0-9.]+"|'[0-9.]+'|[0-9.]+)(?:[ \t]+\#.*|[ \t]*)$""")
    entries = []
    for match in pattern.finditer(text):
        parsed = scalar.fullmatch(match['value'])
        if parsed is None:
            raise ValueError(f'unsupported {key} scalar; use a literal decimal value with optional quotes/comment')
        token = parsed['token']
        value = token.strip("'"+'"')
        grammar = r'[0-9]+\.[0-9]+(?:\.[0-9]+)?' if marketing else r'[0-9]+'
        if re.fullmatch(grammar, value) is None:
            raise ValueError(f'malformed {key}: {value!r}')
        numbers = tuple(int(part, 10) for part in value.split('.'))
        if marketing and len(numbers) == 2:
            numbers += (0,)
        start = match.start('value')
        entries.append((start, start+len(token), numbers))
    if not entries:
        raise ValueError(f'no supported {key} declaration found')
    if any(entry[2] != entries[0][2] for entry in entries):
        raise ValueError(f'inconsistent {key} declarations; align them before bumping')
    for line in text.splitlines():
        if line.lstrip().startswith('#'):
            continue
        if re.search(r"""(?:^|[\s{,])['"]?"""+key+r"""['"]?\s*:""", line) and not pattern.match(line):
            raise ValueError(f'unsupported {key} declaration layout')
    return entries


def main():
    app, mode, build, dry = arguments(sys.argv[1:])
    path = Path(app) / 'project.yml'
    if path.is_symlink():
        raise ValueError('project.yml must not be a symlink')
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError('project.yml must be a regular file')
    original = path.read_bytes()
    text = original.decode('utf-8')
    versions = declarations(text, 'MARKETING_VERSION', True)
    old = versions[0][2]
    major, minor, patch = old
    new = {'major': (major+1, 0, 0), 'minor': (major, minor+1, 0), 'patch': (major, minor, patch+1)}[mode]
    version = '.'.join(map(str, new))
    edits = [(start, end, '"'+version+'"') for start, end, _ in versions]
    new_build = None
    if build:
        builds = declarations(text, 'CURRENT_PROJECT_VERSION', False)
        new_build = builds[0][2][0]+1
        edits += [(start, end, '"'+str(new_build)+'"') for start, end, _ in builds]
    rendered = text
    for start, end, value in sorted(edits, reverse=True):
        rendered = rendered[:start]+value+rendered[end:]
    assert declarations(rendered, 'MARKETING_VERSION', True)[0][2] == new
    if build:
        assert declarations(rendered, 'CURRENT_PROJECT_VERSION', False)[0][2] == (new_build,)
    if not dry:
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(prefix='.project-version-', dir=path.parent, delete=False) as output:
                temporary = output.name
                output.write(rendered.encode('utf-8'))
                output.flush()
                os.fchmod(output.fileno(), stat.S_IMODE(metadata.st_mode))
                os.fsync(output.fileno())
            if path.is_symlink() or path.read_bytes() != original:
                raise ValueError('project.yml changed during preparation; retry')
            os.replace(temporary, path)
            temporary = None
        finally:
            if temporary is not None:
                os.unlink(temporary)
    suffix = f' (build {new_build})' if build else ''
    if dry:
        suffix += ' [dry-run]'
    print(f'→ {app}: {".".join(map(str, old))} → {version}{suffix}', file=sys.stderr)
    print(version)


try:
    main()
except (ValueError, OSError, UnicodeError) as error:
    print(f'version update failed: {error}', file=sys.stderr)
    sys.exit(2)
PY
