#!/bin/bash
#
# pre-commit-lint.sh - Run swift-format and SwiftLint before git commits
#
# This Claude Code hook intercepts git commit commands and runs formatting
# and linting as a safety net. The PostToolUse hook (post-edit-lint.sh)
# catches most issues per-edit; this is the final gate.
#
# Shared via ci_scripts submodule. Project-specific exclusions belong in
# .swiftlint.local.yml (SwiftLint) or .swift-format (swift-format).
#
# Exit code 0 = allow commit, Exit code 2 = block commit
#

# Read the tool input from stdin
input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)

# Print each simple command on its own line, words separated by \037.
# Quotes and backslashes are honored, and ; & | ( ) and newlines end a command,
# so `a && git commit` and `$(git commit)` are both seen while text such as
# `rg 'git commit'` is not. Heredoc bodies aren't recognized and read as commands.
split_commands() {
    printf '%s' "$1" | awk '
        function end_word() {
            if (in_word) { part = part (part == "" ? "" : "\037") word }
            word = ""; in_word = 0
        }
        function end_part() { end_word(); if (part != "") { print part }; part = "" }
        BEGIN { RS = "\001" }
        {
            n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1)
                if (c == "\n" && quote != "") { c = " " }
                if (quote == "\047") {
                    if (c == "\047") { quote = "" } else { word = word c }
                } else if (quote == "\"") {
                    if (c == "\\" && i < n) { i++; word = word substr($0, i, 1) }
                    else if (c == "\"") { quote = "" }
                    else { word = word c }
                } else if (c == "\\" && i < n) {
                    i++; c = substr($0, i, 1)
                    if (c != "\n") { word = word c; in_word = 1 }
                } else if (c == "\047" || c == "\"") {
                    quote = c; in_word = 1
                } else if (c == " " || c == "\t") {
                    end_word()
                } else if (index(";&|()\n", c)) {
                    end_part()
                } else {
                    word = word c; in_word = 1
                }
            }
            end_part()
        }'
}

# Print directory $2 resolved against $1, or $1 when $2 doesn't exist
resolve_dir() {
    local base=$1 target=$2
    case "$target" in
        "~") target=$HOME ;;
        "~/"*) target="$HOME/${target#"~/"}" ;;
        /*) ;;
        *) target="$base/$target" ;;
    esac
    (cd "$target" 2>/dev/null && pwd -P) || printf '%s\n' "$base"
}

# Does this git commit take changes that aren't staged yet (-a, -i, -o, or
# paths)? The hook runs before the command, so it can only check the index.
commit_takes_unstaged() {
    local word opt rest takes_value=false
    for word in "$@"; do
        if $takes_value; then
            takes_value=false
            continue
        fi
        case "$word" in
            '<'* | '>'* | [0-9]'<'* | [0-9]'>'*) return 1 ;;  # redirection: no more arguments
            --) return 0 ;;
            --all | --include | --only | --interactive | --patch | --pathspec-from-file*) return 0 ;;
            --message | --file | --reuse-message | --reedit-message | --template | --author | --date | --cleanup | --fixup | --squash | --trailer)
                takes_value=true ;;
            --*) ;;
            -*)
                rest=${word#-}
                while [ -n "$rest" ]; do
                    opt=${rest:0:1}
                    rest=${rest:1}
                    case "$opt" in
                        a | i | o | p) return 0 ;;
                        m | F | C | c | t)
                            [ -z "$rest" ] && takes_value=true
                            break ;;
                    esac
                done ;;
            *) return 0 ;;  # a path: committed from the working tree
        esac
    done
    return 1
}

# Read the commands in order. Follow `cd` and `git -C` to the repository the
# commit runs in, and note a git command that changes the index before it.
repo_dir="${hook_cwd:-$CLAUDE_PROJECT_DIR}"
is_commit=false
index_changed_by=""
commit_args=()
while IFS= read -r line; do
    IFS=$'\037' read -r -a words <<< "$line"
    # Skip variable assignments and command wrappers
    i=0
    while [ $i -lt ${#words[@]} ]; do
        case "${words[$i]}" in
            [A-Za-z_]*=* | env | command | builtin | exec | nohup | time | sudo | '!' | '{') i=$((i + 1)) ;;
            *) break ;;
        esac
    done
    case "${words[$i]}" in
        cd)
            repo_dir=$(resolve_dir "$repo_dir" "${words[$((i + 1))]:-$HOME}")
            continue ;;
        git | */git) ;;
        *) continue ;;
    esac
    # Skip git's global options; -C changes the directory
    i=$((i + 1))
    git_dir=$repo_dir
    while [ $i -lt ${#words[@]} ]; do
        case "${words[$i]}" in
            -C)
                git_dir=$(resolve_dir "$git_dir" "${words[$((i + 1))]}")
                i=$((i + 2)) ;;
            -c | --git-dir | --work-tree | --namespace | --config-env) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
        esac
    done
    case "${words[$i]}" in
        commit)
            is_commit=true
            repo_dir=$git_dir
            commit_args=("${words[@]:$((i + 1))}")
            break ;;
        add | stage | rm | mv | reset | restore | checkout | stash | apply | update-index)
            index_changed_by="git ${words[$i]}" ;;
    esac
done < <(split_commands "$command")

# Allow all other commands
if ! $is_commit; then
    exit 0
fi

if [ -n "$index_changed_by" ]; then
    echo "Commit blocked: $index_changed_by runs in the same command as git commit, and this hook runs before both, so it can't check what gets staged." >&2
    echo "Run $index_changed_by first, then git commit as its own command." >&2
    exit 2
fi
if commit_takes_unstaged "${commit_args[@]}"; then
    echo "Commit blocked: this git commit includes changes that aren't staged (-a, -i, -o, or paths), which this hook can't check before it runs." >&2
    echo "Stage the files with git add, then run git commit without them." >&2
    exit 2
fi

# Check the repository the commit runs in (a worktree or submodule has its own)
cd "$repo_dir" 2>/dev/null || exit 0
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$repo_root" || exit 0

# Sessions started outside a login shell may lack Apple Silicon Homebrew.
# Add it first so an x86_64 binary in /usr/local/bin, which can't run
# without Rosetta, doesn't win. A PATH that already lists it is kept as is.
if [ -d /opt/homebrew/bin ]; then
    case ":$PATH:" in
        *:/opt/homebrew/bin:*) ;;
        *) export PATH="/opt/homebrew/bin:$PATH" ;;
    esac
fi

# Require both tools — block commit if missing
MISSING_TOOLS=false
if ! swift format --version >/dev/null 2>&1; then
    echo "ERROR: swift-format not available — requires Xcode toolchain (Swift 5.9+)" >&2
    MISSING_TOOLS=true
fi
if ! which swiftlint >/dev/null 2>&1; then
    echo "ERROR: swiftlint not found — install with: brew install swiftlint" >&2
    MISSING_TOOLS=true
elif ! swiftlint version >/dev/null 2>&1; then
    echo "ERROR: $(which swiftlint) can't run (built for another CPU architecture?)" >&2
    MISSING_TOOLS=true
fi
if $MISSING_TOOLS; then
    echo "Commit blocked: required lint tools are missing." >&2
    exit 2
fi

# Check if any Swift files are staged
staged_swift_files=$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACM | grep -E '\.swift$' || true)

if [[ -z "$staged_swift_files" ]]; then
    echo "No Swift files staged, skipping lint." >&2
    exit 0
fi

# A staged file that also has unstaged changes: its working copy isn't what gets committed
is_partly_staged() {
    ! git diff --no-ext-diff --no-textconv --quiet -- ":(literal)$1"
}

# Run swift-format on staged files (auto-fix in place, then re-stage).
# Re-staging adds the whole file, so a file that also has unstaged changes
# is left unformatted: re-staging it would commit those changes too.
if [ -f ".swift-format" ]; then
    echo "Running swift-format on staged files..." >&2
    echo "$staged_swift_files" | while IFS= read -r file; do
        if [ ! -f "$file" ]; then
            continue
        fi
        if is_partly_staged "$file"; then
            echo "warning: $file has unstaged changes, so it was not auto-formatted." >&2
            continue
        fi
        swift format format --configuration .swift-format --in-place "$file" 2>&1
        git add -- ":(literal)$file"
    done
fi

# Run SwiftLint on staged files only (warnings allowed, errors block)
echo "Running SwiftLint on staged files..." >&2

if [ -f ".swiftlint.local.yml" ]; then
    LINT_ARGS=(--config .swiftlint.local.yml)
elif [ -f "ci_scripts/.swiftlint.yml" ]; then
    LINT_ARGS=(--config ci_scripts/.swiftlint.yml)
else
    LINT_ARGS=()
fi

# Re-read staged files (may have changed after formatting)
staged_swift_files=$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACM | grep -E '\.swift$' || true)

full_files=""
partial_files=""
while IFS= read -r file; do
    if [ -z "$file" ]; then
        continue
    fi
    if is_partly_staged "$file"; then
        partial_files+="$file"$'\n'
    else
        full_files+="$file"$'\n'
    fi
done <<< "$staged_swift_files"

LINT_OUTPUT=""
LINT_FAILED=false
if [ -n "$full_files" ]; then
    output=$(printf '%s' "$full_files" | tr '\n' '\0' | xargs -0 swiftlint lint "${LINT_ARGS[@]}" 2>&1) || LINT_FAILED=true
    LINT_OUTPUT+="$output"$'\n'
fi
# Lint what gets committed: the staged content, not the working copy.
# Standard input doesn't apply the config's `excluded` paths.
while IFS= read -r file; do
    if [ -z "$file" ]; then
        continue
    fi
    output=$(git show ":$file" | swiftlint lint --use-stdin "${LINT_ARGS[@]}" 2>&1) || LINT_FAILED=true
    LINT_OUTPUT+="${output//<nopath>/$file (staged)}"$'\n'
done <<< "$partial_files"

if $LINT_FAILED; then
    echo "$LINT_OUTPUT" >&2
    echo "SwiftLint found errors. Please fix before committing." >&2
    exit 2  # Block the commit
fi
echo "SwiftLint passed." >&2
exit 0
