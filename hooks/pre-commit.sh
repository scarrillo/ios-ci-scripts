#!/bin/bash
#
# pre-commit.sh - git pre-commit hook: swift-format and SwiftLint on staged files
#
# Git runs it after staging, so it sees exactly what gets committed, for
# every commit and every client. Shares its checks with the Claude Code hook
# (pre-commit-lint.sh) through lib/swift-checks.sh.
#
# Install from the project root:
#   ln -sf "$PWD/ci_scripts/hooks/pre-commit.sh" "$(git rev-parse --git-path hooks)/pre-commit"
# or call it from another hook manager (for example .husky/pre-commit).
#
# Exit code 0 = allow commit, Exit code 1 = block commit
#

# Find this script's directory, following symlinks (.git/hooks/pre-commit)
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
