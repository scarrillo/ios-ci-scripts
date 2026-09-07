#!/bin/bash
# Claude Code PreToolUse adapter: exit 2 blocks a commit.
input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || {
    echo 'Cannot parse Claude hook input; jq is required.' >&2
    exit 2
}
[[ "$command" == *"git commit"* ]] || exit 0
hook_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 2
if [[ -z "${CLAUDE_PROJECT_DIR:-}" ]]; then
    echo 'CLAUDE_PROJECT_DIR is required.' >&2
    exit 2
fi
cd "$CLAUDE_PROJECT_DIR" || exit 2
bash "$hook_dir/pre-commit.sh"
status=$?
[[ "$status" == 0 ]] && exit 0
exit 2
