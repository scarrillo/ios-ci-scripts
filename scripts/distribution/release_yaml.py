"""Safe, source-position-aware parsing of explicit XcodeGen version settings.

Only project/target settings (simple, base, configs) are interpreted. External
includes, templates, groups and xcconfig files are not resolved or executed.
"""
import re

try:
    import yaml
except ImportError as error:
    raise ImportError('Install the trusted requirements-release.txt in your Python environment') from error


class ReleaseLoader(yaml.SafeLoader):
    """No aliases, explicit tags, recursive graphs, or unbounded nesting."""
    def __init__(self, stream):
        super().__init__(stream)
        self.release_depth = 0
        self.release_nodes = 0

    def compose_node(self, parent, index):
        event = self.peek_event()
        if isinstance(event, yaml.AliasEvent) or getattr(event, 'anchor', None):
            raise ValueError('YAML anchors and aliases are unsupported in release metadata')
        if getattr(event, 'tag', None):
            raise ValueError('explicit YAML tags are unsupported in release metadata')
        self.release_depth += 1
        self.release_nodes += 1
        try:
            if self.release_depth > 64 or self.release_nodes > 50000:
                raise ValueError('release metadata exceeds parser limits')
            return super().compose_node(parent, index)
        finally:
            self.release_depth -= 1


KEYS = ('MARKETING_VERSION', 'CURRENT_PROJECT_VERSION')


def _mapping(node):
    if not isinstance(node, yaml.MappingNode):
        raise ValueError('expected a YAML mapping')
    result = {}
    for key, value in node.value:
        if not isinstance(key, yaml.ScalarNode) or key.tag != 'tag:yaml.org,2002:str':
            raise ValueError('mapping keys must be strings')
        if key.value in result:
            raise ValueError('duplicate YAML key at line ' + str(key.start_mark.line + 1))
        result[key.value] = value
    return result


def _settings_path(path):
    if path[:1] == ('settings',):
        suffix = path[1:]
    elif len(path) >= 3 and path[0] == 'targets' and path[2] == 'settings':
        suffix = path[3:]
    else:
        return False
    # Settings.configs.<name> itself has the Settings schema.
    while len(suffix) >= 2 and suffix[0] == 'configs':
        suffix = suffix[2:]
    return suffix in ((), ('base',))


def _document(text):
    if len(text.encode('utf-8')) > 1024 * 1024:
        raise ValueError('release metadata exceeds 1 MiB')
    try:
        root = yaml.compose(text, Loader=ReleaseLoader)
    except yaml.YAMLError as error:
        # Do not include snippets of contributor metadata in CI diagnostics.
        raise ValueError('invalid YAML project document') from error
    _mapping(root)
    found = {key: [] for key in KEYS}

    def walk(node, path=()):
        if isinstance(node, yaml.MappingNode):
            mapping = _mapping(node)
            if _settings_path(path) and path[-1:] != ('base',):
                advanced = any(key in mapping for key in ('base', 'configs', 'groups'))
                if advanced and any(key not in ('base', 'configs', 'groups') for key in mapping):
                    raise ValueError('mixed simple and advanced XcodeGen settings are unsupported')
            for key, value in mapping.items():
                if key in KEYS:
                    if not _settings_path(path):
                        raise ValueError('version declaration outside supported XcodeGen settings')
                    if not isinstance(value, yaml.ScalarNode) or value.style in ('|', '>'):
                        raise ValueError('version settings must be literal scalars')
                    found[key].append(value)
                walk(value, path + (key,))
        elif isinstance(node, yaml.SequenceNode):
            for value in node.value:
                walk(value, path + ('[]',))

    walk(root)
    return found


def declarations(text, key, marketing):
    """Return exact scalar spans and normalized decimals; never re-emit YAML."""
    if key not in KEYS or marketing != (key == KEYS[0]):
        raise ValueError('unsupported release setting')
    found = _document(text)
    parsed = {}
    for name, nodes in found.items():
        values = []
        for node in nodes:
            grammar = r'[0-9]+\.[0-9]+(?:\.[0-9]+)?' if name == KEYS[0] else r'[0-9]+'
            if re.fullmatch(grammar, node.value) is None:
                raise ValueError('malformed ' + name)
            numbers = tuple(int(part, 10) for part in node.value.split('.'))
            if name == KEYS[0] and len(numbers) == 2:
                numbers += (0,)
            values.append((node.start_mark.index, node.end_mark.index, numbers))
        if values and any(item[2] != values[0][2] for item in values):
            raise ValueError('inconsistent ' + name + ' declarations')
        parsed[name] = values
    if not parsed[key]:
        raise ValueError('no supported ' + key + ' declaration found')
    return parsed[key]


def metadata(text):
    version = declarations(text, KEYS[0], True)[0][2]
    build = declarations(text, KEYS[1], False)[0][2][0]
    return '.'.join(map(str, version)), str(build)
