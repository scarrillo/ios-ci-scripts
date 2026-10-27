#!/bin/bash
#
# install-git-hooks.sh - Install the git hooks that run the Swift checks
#
# Usage, from the project root:
#   ci_scripts/hooks/install-git-hooks.sh            # report to the terminal
#   ci_scripts/hooks/install-git-hooks.sh --quiet    # report only what needs action
#   ci_scripts/hooks/install-git-hooks.sh --claude   # the same, as Claude Code JSON
#
# Writes a small pre-commit and post-commit hook into the repository's hooks
# directory (.git/hooks, shared by all worktrees). Each runs pre-commit.sh or
# post-commit.sh from the checkout making the commit, so every worktree uses
# its own copy of these scripts. Git doesn't track .git/hooks, so checking out
# a branch can't change what runs. Run it from a Claude Code SessionStart hook
# so every session has them. It never replaces a hook: when one is already
# there, or core.hooksPath points elsewhere, it reports how to call these
# instead. Safe to run again. Always exits 0.
#

# These scripts' directory as it was called, before changing directories
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

mode=terminal
case "$1" in
    --quiet) mode=quiet ;;
    --claude)
        mode=claude
        cat >/dev/null ;;  # the SessionStart input isn't needed
esac

notes=""     # what was done
problems=""  # what needs action
report() {
    case "$mode" in
        terminal) printf '%s%s' "$notes" "$problems" ;;
        quiet) printf '%s' "$problems" ;;
        claude)
            if [ -n "$problems" ]; then
                jq -n --arg context "install-git-hooks: $problems" \
                    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}}' 2>/dev/null ||
                    printf '%s' "$problems" >&2
            fi ;;
    esac
    exit 0
}

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" || exit 0

# These scripts' path in the project, such as ci_scripts/hooks: the longest
# end of script_dir that names the same directory inside the project, so a
# symlinked project or ci_scripts directory works
rel=""
suffix=${script_dir#/}
while [ -n "$suffix" ]; do
    if [ "$root/$suffix" -ef "$script_dir" ]; then
        rel=$suffix
        break
    fi
    case "$suffix" in
        */*) suffix=${suffix#*/} ;;
        *) suffix="" ;;
    esac
done
if [ -z "$rel" ]; then
    problems+="$script_dir isn't inside this repository ($root), so a hook can't run the Swift checks from the checkout making the commit. Add ci_scripts to the project, for example as a submodule, and run this from there."$'\n'
    report
fi

# The line that runs one of these hooks from another hook
call_line() {
    printf '"$(git rev-parse --show-toplevel)/%s/%s.sh" || exit 1' "$rel" "$1"
}

# A hook that runs one of these scripts from the checkout making the commit
write_hook() {
    cat <<EOF
#!/bin/sh
# Runs the shared Swift checks in $rel/$1.sh from the checkout making the
# commit. Installed by $rel/install-git-hooks.sh.
hook="\$(git rev-parse --show-toplevel)/$rel/$1.sh"
if [ ! -f "\$hook" ]; then
    echo "error: \$hook is missing. Run: git submodule update --init" >&2
    exit 1
fi
exec "\$hook" "\$@"
EOF
}

dir=$(git rev-parse --git-path hooks)
hooks_path=$(git config core.hooksPath)
if [ -n "$hooks_path" ]; then
    # Another tool, such as a hook manager, owns the hooks: they must call these
    for name in pre-commit post-commit; do
        if ! grep -qF "$rel/$name.sh" "$dir/$name" 2>/dev/null; then
            problems+="core.hooksPath is $hooks_path, so hooks run from $dir. To add the Swift checks, call this from $dir/$name: $(call_line "$name")"$'\n'
        fi
    done
    report
fi

mkdir -p "$dir" || report
for name in pre-commit post-commit; do
    hook=$dir/$name
    if [ ! -e "$hook" ] && [ ! -L "$hook" ]; then
        if write_hook "$name" > "$hook" && chmod +x "$hook"; then
            notes+="Installed $hook."$'\n'
        fi
    elif ! grep -qF "$rel/$name.sh" "$hook" 2>/dev/null; then
        problems+="$hook already exists and isn't this hook, so it was left alone. To add the Swift checks, call this from it: $(call_line "$name")"$'\n'
    elif [ ! -x "$hook" ]; then
        problems+="$hook isn't executable, so git skips it. Run: chmod +x $hook"$'\n'
    fi
done
report
