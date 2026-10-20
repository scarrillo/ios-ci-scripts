#!/bin/bash
#
# pre-commit-lint.sh - Run swift-format and SwiftLint before git commits
#
# This Claude Code hook intercepts git commit commands and runs formatting
# and linting as a safety net. The PostToolUse hook (post-edit-lint.sh)
# catches most issues per-edit; this is the final gate. The checks are shared
# with pre-commit.sh, the git hook, through lib/swift-checks.sh.
#
# Shared via ci_scripts submodule. Project-specific exclusions belong in
# .swiftlint.local.yml (SwiftLint) or .swift-format (swift-format).
#
# Exit code 0 = allow commit, Exit code 2 = block commit
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
swift_checks_path

# Read the tool input from stdin
input=$(cat)
# Without jq the command can't be read. Block what looks like a commit, so
# the check isn't skipped silently, and let everything else through.
if ! command -v jq >/dev/null 2>&1; then
    case "$input" in
        *git*commit*)
            echo "Commit blocked: jq is required to check commits — install with: brew install jq" >&2
            exit 2 ;;
    esac
    exit 0
fi
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
hook_cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)

# Print each simple command on its own line, words separated by \037.
# Quotes and backslashes are honored, and ; & | and newlines end a command.
# $(...), backticks, and ( ) are scanned as commands too, even inside double
# quotes, between "\002(" and "\002)" lines that mark their scope. So
# `a && git commit` and `x="$(git commit)"` are seen while text such as
# `rg 'git commit'` is not. Each part of a pipeline is scoped like a subshell.
# Heredoc bodies and comments are skipped. A word that starts quoted or
# escaped is prefixed with \003, so '>file' isn't a redirection.
split_commands() {
    printf '%s' "$1" | awk '
        function end_word() {
            if (in_word) {
                part = part (part == "" ? "" : "\037") word
                if (want_delim) {
                    delim = word; sub(/^\003/, "", delim)
                    heredocs++; heredoc_delim[heredocs] = delim; heredoc_tabs[heredocs] = want_tabs
                    want_delim = 0
                }
            }
            word = ""; in_word = 0
        }
        function start_word() { if (!in_word) { word = "\003"; in_word = 1 } }
        function skip_heredoc_bodies(   k, rest, nl, body_line) {
            for (k = 1; k <= heredocs; k++) {
                while (i < n) {
                    rest = substr($0, i + 1); nl = index(rest, "\n")
                    body_line = nl ? substr(rest, 1, nl - 1) : rest
                    i += nl ? nl : length(rest)
                    if (heredoc_tabs[k]) { sub(/^\t+/, "", body_line) }
                    if (body_line == heredoc_delim[k]) { break }
                }
            }
            heredocs = 0
        }
        function end_part() {
            end_word()
            if (part != "") {
                if (piped) { print "\002("; print part; print "\002)" } else { print part }
            }
            part = ""; piped = 0
        }
        function open_subst(kind) {
            d++; saved_part[d] = part; saved_word[d] = word; saved_quote[d] = quote; saved_piped[d] = piped; kind_at[d] = kind
            part = ""; word = ""; in_word = 0; quote = ""; piped = 0
            print "\002("
        }
        function close_subst() {
            end_part(); print "\002)"
            part = saved_part[d]; word = saved_word[d]; quote = saved_quote[d]; piped = saved_piped[d]; in_word = 1; d--
        }
        function open_group() { end_part(); d++; kind_at[d] = "("; print "\002(" }
        function close_group() { end_part(); print "\002)"; d-- }
        BEGIN { RS = "\001"; d = 0 }
        {
            n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1); next_c = substr($0, i + 1, 1)
                if (quote == "\"") {
                    if (c == "\\" && i < n) { i++; word = word substr($0, i, 1) }
                    else if (c == "\"") { quote = "" }
                    else if (c == "$" && next_c == "(") { i++; open_subst("$(") }
                    else if (c == "`") { open_subst("`") }
                    else { word = word (c == "\n" ? " " : c) }
                    continue
                }
                if (c == "\047") {
                    start_word()
                    j = index(substr($0, i + 1), "\047")
                    if (j == 0) { text = substr($0, i + 1); i = n } else { text = substr($0, i + 1, j - 1); i += j }
                    gsub(/\n/, " ", text); word = word text
                } else if (c == "\\" && i < n) {
                    i++; c = substr($0, i, 1)
                    if (c != "\n") { start_word(); word = word c }
                } else if (c == "\"") {
                    quote = c; start_word()
                } else if (c == "$" && next_c == "(") {
                    i++; in_word = 1; open_subst("$(")
                } else if (c == "`") {
                    if (d > 0 && kind_at[d] == "`") { close_subst() } else { in_word = 1; open_subst("`") }
                } else if (c == "(") {
                    open_group()
                } else if (c == ")") {
                    if (d > 0 && kind_at[d] == "$(") { close_subst() }
                    else if (d > 0 && kind_at[d] == "(") { close_group() }
                    else { end_part() }
                } else if (c == "&") {
                    last = substr(word, length(word), 1)
                    if (in_word && (last == ">" || last == "<")) { word = word c }  # >& and <&
                    else if (next_c == ">") { end_word(); word = c; in_word = 1 }  # &>
                    else { end_part() }
                } else if (c == "<" && next_c == "<" && substr($0, i + 2, 1) != "<") {
                    end_word(); i++; word = "<<"; in_word = 1; want_tabs = 0
                    if (substr($0, i + 1, 1) == "-") { i++; word = word "-"; want_tabs = 1 }
                    end_word(); want_delim = 1
                } else if (c == "#" && !in_word) {
                    j = index(substr($0, i + 1), "\n")
                    i = j ? i + j - 1 : n  # to the end of the line
                } else if (c == "|" && next_c == "|") {
                    i++; end_part()
                } else if (c == "|") {
                    if (next_c == "&") { i++ }
                    piped = 1; end_part(); piped = 1  # both sides of a pipe run in subshells
                } else if (c == " " || c == "\t") {
                    end_word()
                } else if (c == ";" || c == "\n") {
                    end_part()
                    if (c == "\n" && heredocs > 0) { skip_heredoc_bodies() }
                } else {
                    word = word c; in_word = 1
                }
            }
            end_part()
        }'
}

# Is $1 a redirection? Sets REDIRECT to "operator" when its target is the
# next word, or "attached" when the target is in the same word.
redirect_kind() {
    REDIRECT=""
    case "$1" in
        '>'* | '<'* | '&>'* | [0-9]'>'* | [0-9]'<'*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *'>' | *'<' | *'&' | *'>|' | *'<<-') REDIRECT=operator ;;
        *) REDIRECT=attached ;;
    esac
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
    local word opt rest name long takes_value=false
    for word in "$@"; do
        if $takes_value; then
            takes_value=false
            continue
        fi
        case "$word" in
            $'\003'*) word=${word#$'\003'} ;;
            *)
                if redirect_kind "$word"; then
                    [ "$REDIRECT" = operator ] && takes_value=true
                    continue
                fi ;;
        esac
        case "$word" in
            --) return 0 ;;
            --*)
                # Git accepts any unambiguous prefix of a long option
                name=${word%%=*}
                for long in --all --include --only --interactive --patch --pathspec-from-file; do
                    case "$long" in
                        "$name"*) return 0 ;;
                    esac
                done
                if [ "$name" = "$word" ]; then
                    for long in --message --file --reuse-message --reedit-message --template --author --date --cleanup --fixup --squash --trailer; do
                        case "$long" in
                            "$name"*)
                                takes_value=true
                                break ;;
                        esac
                    done
                fi ;;
            -*)
                rest=${word#-}
                while [ -n "$rest" ]; do
                    opt=${rest:0:1}
                    rest=${rest:1}
                    case "$opt" in
                        a | i | o | p) return 0 ;;
                        u | S) break ;;  # the rest is their optional value (-uno)
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

# Is there a `git ... commit` in words $1 onward?
words_have_git_commit() {
    local j=$1 seen_git=false
    while [ $j -lt ${#words[@]} ]; do
        case "${words[$j]}" in
            git | */git) seen_git=true ;;
            commit) $seen_git && return 0 ;;
        esac
        j=$((j + 1))
    done
    return 1
}

# Read the commands in order. Follow `cd` and `git -C` to the repository the
# commit runs in, restoring the directory when a subshell ends. Note any git
# command before the commit that isn't known to leave the index alone, and any
# form the hook can't follow, so the commit is blocked rather than unchecked.
repo_dir="${hook_cwd:-$CLAUDE_PROJECT_DIR}"
dir_stack=()
commit_count=0
commit_dir=""
commit_args=()
index_changed_by=""
repo_override=""
wrapper_options=""
while IFS= read -r line; do
    case "$line" in
        $'\002(')
            dir_stack+=("$repo_dir")
            continue ;;
        $'\002)')
            if [ ${#dir_stack[@]} -gt 0 ]; then
                last=$((${#dir_stack[@]} - 1))
                repo_dir=${dir_stack[$last]}
                unset "dir_stack[$last]"
            fi
            continue ;;
    esac
    IFS=$'\037' read -r -a words <<< "$line"
    # Strip the quoted-word marker, remembering which words had it
    quoted=()
    k=0
    while [ $k -lt ${#words[@]} ]; do
        case "${words[$k]}" in
            $'\003'*) quoted[$k]=true; words[$k]=${words[$k]#$'\003'} ;;
            *) quoted[$k]=false ;;
        esac
        k=$((k + 1))
    done
    # Skip variable assignments, redirections, shell keywords, and command wrappers
    i=0
    while [ $i -lt ${#words[@]} ]; do
        word=${words[$i]}
        if ! ${quoted[$i]} && redirect_kind "$word"; then
            [ "$REDIRECT" = operator ] && i=$((i + 1))
            i=$((i + 1))
            continue
        fi
        case "$word" in
            GIT_DIR=* | GIT_WORK_TREE=* | GIT_INDEX_FILE=*)
                repo_override=${word%%=*}
                i=$((i + 1)) ;;
            env | */env | command | builtin | exec | nohup | */nohup | time | */time | sudo | */sudo | \
                nice | */nice | timeout | */timeout | xargs | */xargs | caffeinate | */caffeinate)
                # A wrapper's options can take operands; don't guess past them. The
                # last four always take arguments or read their commands elsewhere.
                case "${word##*/}" in
                    nice | timeout | xargs | caffeinate) opaque=true ;;
                    *) [ "${words[$((i + 1))]:0:1}" = - ] && opaque=true || opaque=false ;;
                esac
                if $opaque; then
                    if words_have_git_commit $((i + 1)); then
                        commit_count=$((commit_count + 1))
                        wrapper_options=${word##*/}
                    fi
                    continue 2
                fi
                i=$((i + 1)) ;;
            function) i=$((i + 2)) ;;  # function name { ...; }
            [A-Za-z_]*=* | if | then | else | elif | do | while | until | '!' | '{') i=$((i + 1)) ;;
            *) break ;;
        esac
    done
    case "${words[$i]}" in
        cd)
            repo_dir=$(resolve_dir "$repo_dir" "${words[$((i + 1))]:-$HOME}")
            continue ;;
        export | declare | typeset)
            for word in "${words[@]:$((i + 1))}"; do
                case "$word" in
                    GIT_DIR=* | GIT_WORK_TREE=* | GIT_INDEX_FILE=*) repo_override=${word%%=*} ;;
                esac
            done
            continue ;;
        git | */git) ;;
        *) continue ;;
    esac
    # Skip git's global options; -C changes the directory
    i=$((i + 1))
    git_dir=$repo_dir
    while [ $i -lt ${#words[@]} ]; do
        word=${words[$i]}
        if ! ${quoted[$i]} && redirect_kind "$word"; then
            [ "$REDIRECT" = operator ] && i=$((i + 1))
            i=$((i + 1))
            continue
        fi
        case "$word" in
            -C)
                git_dir=$(resolve_dir "$git_dir" "${words[$((i + 1))]}")
                i=$((i + 2)) ;;
            --git-dir | --work-tree)
                repo_override=$word
                i=$((i + 2)) ;;
            --git-dir=* | --work-tree=*)
                repo_override=${word%%=*}
                i=$((i + 1)) ;;
            -c | --namespace | --config-env) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
        esac
    done
    case "${words[$i]}" in
        commit)
            commit_count=$((commit_count + 1))
            if [ $commit_count = 1 ]; then
                commit_dir=$git_dir
                commit_args=()
                k=$((i + 1))
                while [ $k -lt ${#words[@]} ]; do
                    if ${quoted[$k]}; then
                        commit_args+=($'\003'"${words[$k]}")
                    else
                        commit_args+=("${words[$k]}")
                    fi
                    k=$((k + 1))
                done
            fi ;;
        # Known to leave the index alone
        "" | status | diff | log | show | rev-parse | rev-list | ls-files | ls-tree | cat-file | describe | \
            blame | grep | shortlog | show-ref | for-each-ref | symbolic-ref | merge-base | name-rev | \
            check-ignore | check-attr | fetch | remote | push | branch | tag | config | version | help | var) ;;
        *)
            if [ $commit_count = 0 ]; then
                index_changed_by="git ${words[$i]}"
            fi ;;
    esac
done < <(split_commands "$command")

# Allow all other commands
if [ $commit_count = 0 ]; then
    exit 0
fi

if [ -n "$wrapper_options" ]; then
    echo "Commit blocked: git commit runs under $wrapper_options with options or arguments this hook can't follow." >&2
    echo "Run git commit directly, without $wrapper_options." >&2
    exit 2
fi
if [ $commit_count -gt 1 ]; then
    echo "Commit blocked: this command runs git commit $commit_count times, and this hook can only check what is staged before the first." >&2
    echo "Run each git commit as its own command." >&2
    exit 2
fi
if [ -n "$repo_override" ]; then
    echo "Commit blocked: $repo_override points git at a repository or index this hook can't follow." >&2
    echo "Run git commit from inside the repository, without $repo_override." >&2
    exit 2
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
cd "$commit_dir" 2>/dev/null || exit 0
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$repo_root" || exit 0

messages=$(swift_checks_staged 2>&1)
status=$?
if [ $status -ne 0 ]; then
    printf '%s\n' "$messages" >&2
    exit 2  # Block the commit
fi
printf '%s\n' "$messages" >&2
# Claude only sees a passing hook's output as JSON, so send the warnings that way
warnings=$(printf '%s\n' "$messages" | grep '^warning: ' || true)
if [ -n "$warnings" ]; then
    jq -n --arg context "pre-commit-lint: $warnings" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $context}}'
fi
exit 0
