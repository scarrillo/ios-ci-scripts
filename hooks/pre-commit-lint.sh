#!/bin/bash
#
# pre-commit-lint.sh - Compatibility shim for an older Claude Code setup
#
# Projects whose .claude/settings.json still runs this as a PreToolUse hook
# for Bash keep working: it makes sure the git hooks are installed and allows
# every command. The commit checks run in the git pre-commit hook
# (pre-commit.sh), which sees exactly what gets committed. New setups use the
# SessionStart hook in the README instead of this one.
#

# Find this script's directory, following symlinks
source_path=${BASH_SOURCE[0]}
while [ -L "$source_path" ]; do
    link_dir=$(cd -P "$(dirname "$source_path")" && pwd)
    source_path=$(readlink "$source_path")
    case "$source_path" in
        /*) ;;
        *) source_path="$link_dir/$source_path" ;;
    esac
done
hook_dir=$(cd -P "$(dirname "$source_path")" && pwd)

cat >/dev/null  # the tool input isn't needed
"$hook_dir/install-git-hooks.sh" >/dev/null 2>&1
exit 0
