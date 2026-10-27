#!/bin/bash
#
# post-commit.sh - git post-commit hook: check commits pre-commit.sh didn't see
#
# Git runs post-commit even after git commit --no-verify, which skips
# pre-commit.sh. When the new commit's content isn't the tree pre-commit.sh
# passed, this checks the commit's Swift files and warns. It can't undo the
# commit; fix the files and commit again.
#
# install-git-hooks.sh sets up .githooks/post-commit to run it. Always exits
# 0: git ignores it anyway.
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

cd "$(git rev-parse --show-toplevel)" || exit 0

# A rebase replays commits that were checked when first made
for state in rebase-merge rebase-apply; do
    if [ -d "$(git rev-parse --git-path "$state")" ]; then
        exit 0
    fi
done

marker=$(swift_checks_marker)
if [ -f "$marker" ] && [ "$(cat "$marker")" = "$(git rev-parse 'HEAD^{tree}')" ]; then
    exit 0  # pre-commit.sh passed exactly this content
fi

if ! swift_checks_commit HEAD; then
    echo "warning: commit $(git rev-parse --short HEAD) wasn't checked before it was made (git commit --no-verify, or no pre-commit hook) and has the issues above. Fix them and commit again." >&2
fi
exit 0
