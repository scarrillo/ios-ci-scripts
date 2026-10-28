#!/bin/bash
#
# pre-commit-lint.sh - Compatibility shim for an older Claude Code setup
#
# Projects whose .claude/settings.json still runs this as a PreToolUse hook
# for Bash keep working: it runs install-git-hooks.sh, which sets up the git
# hooks that check commits (pre-commit.sh sees exactly what gets committed),
# and allows every command. When the setup needs action, it tells Claude
# once per session. New setups use the SessionStart hook in the README
# instead of this one.
#

hook_dir=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source=lib/swift-checks.sh
source "$hook_dir/lib/swift-checks.sh"
swift_checks_path  # for jq

input=$(cat)
report=$("$hook_dir/install-git-hooks.sh" --quiet 2>/dev/null)
if [ -z "$report" ]; then
    exit 0
fi

# Report once per session: this runs before every Bash command
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
stamp=$(git rev-parse --git-path swift-checks-reported 2>/dev/null) || exit 0
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
if [ -n "$session" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$session" ]; then
    exit 0
fi
printf '%s\n' "$session" > "$stamp" 2>/dev/null
jq -n --arg context "install-git-hooks: $report" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $context}}' 2>/dev/null
exit 0
