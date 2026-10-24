#!/bin/bash
#
# install-git-hooks.sh - Link pre-commit.sh and post-commit.sh as git hooks
#
# Usage, from the project root:
#   ci_scripts/hooks/install-git-hooks.sh            # report to the terminal
#   ci_scripts/hooks/install-git-hooks.sh --claude   # report as Claude Code JSON
#
# Run it from a Claude Code SessionStart hook so every session has the hooks.
# Safe to run again: correct links are kept, and a link to this script from an
# old location is replaced. Uses the repository's hooks directory, including
# core.hooksPath. An existing hook that isn't one of these is never replaced;
# the report says how to call these from it. Always exits 0.
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

claude=false
if [ "$1" = --claude ]; then
    claude=true
    cat >/dev/null  # the SessionStart input isn't needed
fi

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" || exit 0
hooks=$(git rev-parse --git-path hooks)
mkdir -p "$hooks" || exit 0
# These scripts' path in the project, such as ci_scripts/hooks
rel=${hook_dir#"$root"/}

report=""
for name in pre-commit post-commit; do
    target="$hook_dir/$name.sh"
    dest="$hooks/$name"
    if [ -L "$dest" ]; then
        current=$(readlink "$dest")
        if [ "$current" = "$target" ]; then
            continue
        fi
        case "$current" in
            */"$rel/$name.sh" | "$rel/$name.sh")
                # This hook from another location, such as a moved clone
                ln -sf "$target" "$dest" && report+="Updated $dest to $target."$'\n'
                continue ;;
        esac
    elif [ ! -e "$dest" ]; then
        ln -s "$target" "$dest" && report+="Installed $dest."$'\n'
        continue
    elif grep -qF "$rel/$name.sh" "$dest" 2>/dev/null; then
        continue  # an existing hook that already calls this one
    fi
    report+="$dest already exists and isn't this hook, so it was left alone. To add the Swift checks, call this from it: \"\$(git rev-parse --show-toplevel)/$rel/$name.sh\" || exit 1"$'\n'
done

if [ -z "$report" ]; then
    exit 0
fi
if $claude; then
    case "$report" in
        *"left alone"*)
            jq -n --arg context "install-git-hooks: $report" \
                '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}}' 2>/dev/null ||
                printf '%s' "$report" >&2 ;;
    esac
else
    printf '%s' "$report"
fi
exit 0
