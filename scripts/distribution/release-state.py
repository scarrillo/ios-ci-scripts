"""Pure release decisions; no filesystem, Git, network, or mutation.

Adapters must supply validated scalar strings from trusted parsing, attribute
changes using the historical merge base, and compare against the current base.
These decisions do not enforce branch freshness or certify compilation.
"""
import re


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


def baseline(candidates, reachable_commits):
    """Select highest version reachable from the exact merge, including itself.

    candidates are (tag_name, version_scalar, peeled_commit) triples for ONE
    consumer-selected release namespace. The adapter obtains reachability from
    Git, not from PR input. No candidate means None; invalid/ambiguous reachable
    release versions fail closed. Tag-at-merge is retained for retry handling.
    """
    reachable = set(reachable_commits)
    eligible = [(version(value), name, commit)
                for name, value, commit in candidates if commit in reachable]
    if not eligible:
        return None
    highest = max(item[0] for item in eligible)
    winners = {(name, commit) for value, name, commit in eligible if value == highest}
    if len(winners) != 1:
        raise ValueError('ambiguous release baseline')
    return next(iter(winners))[0]
