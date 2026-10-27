#!/bin/bash
#
# install-git-hooks.sh - Set up the project's tracked git hooks in .githooks
#
# Usage, from the project root:
#   ci_scripts/hooks/install-git-hooks.sh            # report to the terminal
#   ci_scripts/hooks/install-git-hooks.sh --quiet    # report only what needs action
#   ci_scripts/hooks/install-git-hooks.sh --claude   # the same, as Claude Code JSON
#
# The project commits .githooks/pre-commit and .githooks/post-commit, which
# run pre-commit.sh and post-commit.sh from the checkout making the commit,
# so every clone and worktree uses its own copy of these scripts. This
# creates those files when they're missing and sets core.hooksPath to
# .githooks, which all worktrees share. Run it from a Claude Code SessionStart
# hook so every session has them. It never replaces a hook: when
# core.hooksPath points elsewhere, or .git/hooks has hooks that setting it
# would turn off, it reports what to change instead. Safe to run again.
# Always exits 0.
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
    problems+="$script_dir isn't inside this repository ($root), so a tracked hook can't run the Swift checks from it. Add ci_scripts to the project, for example as a submodule, and run this from there."$'\n'
    report
fi

# The line that runs one of these hooks from another hook
call_line() {
    printf '"$(git rev-parse --show-toplevel)/%s/%s.sh" || exit 1' "$rel" "$1"
}

hooks_path=$(git config core.hooksPath)
case "$hooks_path" in
    "" | .githooks | .githooks/) ;;
    *)
        # Another hooks directory, such as a hook manager's: it must call these
        dir=$(git rev-parse --git-path hooks)
        for name in pre-commit post-commit; do
            if ! grep -qF "$rel/$name.sh" "$dir/$name" 2>/dev/null; then
                problems+="core.hooksPath is $hooks_path, so .githooks isn't used. To add the Swift checks, call this from $dir/$name: $(call_line "$name")"$'\n'
            fi
        done
        report ;;
esac

if [ -z "$hooks_path" ]; then
    # Setting core.hooksPath stops git from running the hooks in .git/hooks
    default=$(git rev-parse --git-path hooks)
    active=""
    for hook in "$default"/*; do
        case "$hook" in
            *.sample) continue ;;
        esac
        if [ -f "$hook" ] && [ -x "$hook" ]; then
            active+=" ${hook##*/}"
        fi
    done
    if [ -n "$active" ]; then
        problems+="core.hooksPath wasn't set to .githooks, because git would then stop running these hooks in $default:$active. Move them into .githooks (or call them from its hooks), remove them from $default, and run $rel/install-git-hooks.sh again."$'\n'
        report
    fi
fi

# A tracked hook that runs one of these scripts from the checkout committing
write_hook() {
    cat <<EOF
#!/bin/sh
# Runs the shared Swift checks in $rel/$1.sh from the checkout making the
# commit. Created by $rel/install-git-hooks.sh.
hook="\$(git rev-parse --show-toplevel)/$rel/$1.sh"
if [ ! -f "\$hook" ]; then
    echo "error: \$hook is missing. Run: git submodule update --init" >&2
    exit 1
fi
exec "\$hook" "\$@"
EOF
}

mkdir -p .githooks || report
untracked=""
for name in pre-commit post-commit; do
    hook=.githooks/$name
    if [ ! -e "$hook" ] && [ ! -L "$hook" ]; then
        if write_hook "$name" > "$hook" && chmod +x "$hook"; then
            notes+="Created $hook."$'\n'
        fi
    elif ! grep -qF "$rel/$name.sh" "$hook" 2>/dev/null; then
        problems+="$hook doesn't run the Swift checks. Add: $(call_line "$name")"$'\n'
    elif [ ! -x "$hook" ]; then
        problems+="$hook isn't executable, so git skips it. Run: chmod +x $hook"$'\n'
    fi
    if ! git ls-files --error-unmatch -- "$hook" >/dev/null 2>&1; then
        untracked+=" $hook"
    fi
done
if [ -n "$untracked" ]; then
    problems+="Commit$untracked, so every clone and worktree runs the Swift checks."$'\n'
fi
if [ -z "$hooks_path" ] && git config core.hooksPath .githooks; then
    notes+="Set core.hooksPath to .githooks."$'\n'
fi
report
