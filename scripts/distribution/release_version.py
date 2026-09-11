import os
from pathlib import Path
import importlib.util
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


spec = importlib.util.spec_from_file_location('release_yaml', Path(__file__).with_name('release_yaml.py'))
release_yaml = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(release_yaml)
except ImportError as error:
    print(str(error), file=sys.stderr)
    sys.exit(2)
declarations = release_yaml.declarations


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
    if declarations(rendered, 'MARKETING_VERSION', True)[0][2] != new:
        raise ValueError('rendered MARKETING_VERSION does not match requested version')
    if build:
        if declarations(rendered, 'CURRENT_PROJECT_VERSION', False)[0][2] != (new_build,):
            raise ValueError('rendered CURRENT_PROJECT_VERSION does not match requested build')
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
