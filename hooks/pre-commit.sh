#!/bin/bash
#
# pre-commit.sh - git pre-commit hook: swift-format and SwiftLint on staged files
#
# Git runs it after staging, so it sees exactly what gets committed, for
# every commit, client, and shell. The checks live in lib/swift-checks.sh.
# On success it records the staged tree, so post-commit.sh can tell this
# commit was checked.
#
# install-git-hooks.sh sets up .githooks/pre-commit to run it. From another
# hook or a hook manager (for example .husky/pre-commit), call:
#   "$(git rev-parse --show-toplevel)/ci_scripts/hooks/pre-commit.sh" || exit 1
#
# Exit code 0 = allow commit, Exit code 1 = block commit
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
# shellcheck source=lib/swift-checks.sh
source "$hook_dir/lib/swift-checks.sh"

cd "$(git rev-parse --show-toplevel)" || exit 1
swift_checks_staged || exit 1
git write-tree > "$(swift_checks_marker)" 2>/dev/null || true
