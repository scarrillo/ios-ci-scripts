#!/bin/bash
#
# hooks.sh - Tests for hooks/pre-commit-lint.sh, hooks/pre-commit.sh, and
# hooks/post-edit-lint.sh, run against throwaway repositories.
#
# Usage: tests/hooks.sh
# Requires git, jq, swift-format (Xcode toolchain), and swiftlint. Runs with
# the system bash (3.2 on macOS) like the hooks themselves.
#

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
H=$ROOT/hooks
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ci-scripts-hook-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

for tool in git jq swiftlint; do
    command -v "$tool" >/dev/null 2>&1 || PATH="/opt/homebrew/bin:$PATH"
    command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool is not installed"; exit 0; }
done
swift format --version >/dev/null 2>&1 || { echo "skip: swift-format is not available"; exit 0; }

# PATH as Xcode or a GUI-launched session sees it: no Homebrew
NOBREW="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
UNFORMATTED='struct Sample {\n  let value = 1\n}\n'
LINT_ERROR='let value: Any = 1\nlet number = value as! Int\n'
CLEAN='let value = 1\n'
pass=0
fail=0

# A repository with a .swift-format and a .swiftlint.local.yml that inherits
# from ci_scripts/.swiftlint.yml, as a consuming project has
mkrepo() {
    rm -rf "$1"
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" config user.email test@example.com
    git -C "$1" config user.name Test
    git -C "$1" config commit.gpgsign false
    printf '{ "version": 1, "indentation": { "spaces": 4 }, "lineLength": 1000 }\n' > "$1/.swift-format"
    printf 'parent_config: ci_scripts/.swiftlint.yml\n' > "$1/.swiftlint.local.yml"
    ln -s "$ROOT" "$1/ci_scripts"
}
# Run the Claude Code commit hook: pre <cwd> <command>; sets OUT and CODE
pre() {
    OUT=$(jq -n --arg c "$2" --arg d "$1" '{tool_input: {command: $c}, cwd: $d}' |
        env PATH="$NOBREW" CLAUDE_PROJECT_DIR="$T" /bin/bash "$H/pre-commit-lint.sh" 2>&1)
    CODE=$?
}
# Run the edit hook: post <file>; sets OUT and CODE
post() {
    OUT=$(jq -n --arg f "$1" '{tool_input: {file_path: $f}}' |
        env PATH="$NOBREW" CLAUDE_PROJECT_DIR="$T" /bin/bash "$H/post-edit-lint.sh" 2>/dev/null)
    CODE=$?
}
check() {  # name, 0 when it passed
    if [ "$2" = 0 ]; then
        pass=$((pass + 1))
        echo "ok   $1"
    else
        fail=$((fail + 1))
        echo "FAIL $1"
        printf '%s\n' "$OUT" | sed 's/^/       /'
    fi
}
expect() {  # name, expected exit code, optional text the output must contain
    local result=0
    [ "$CODE" = "$2" ] || result=1
    if [ -n "$3" ] && ! printf '%s' "$OUT" | grep -qF -- "$3"; then
        result=1
    fi
    check "$1 (exit $CODE)" $result
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }

T=$WORK/main
O=$WORK/other

echo "== Claude hook: which commands count as commits"
mkrepo "$T"
printf "$UNFORMATTED" > "$T/Sample.swift"
git -C "$T" add Sample.swift
staged=$(git -C "$T" rev-parse :Sample.swift)
pre "$T" "rg -n 'git commit' readme.md";                 expect "rg 'git commit' is ignored" 0
pre "$T" 'echo "x && git commit -m y"';                  expect "quoted && git commit is ignored" 0
pre "$T" "rg 'git commit \$(x)' f";                      expect "single quotes stay text" 0
check "index untouched by ignored commands" "$(yes_if [ "$staged" = "$(git -C "$T" rev-parse :Sample.swift)" ])"
pre "$T" "git status && git commit -m t";                expect "status then commit is checked" 0 "SwiftLint passed"
check "staged file formatted" "$(yes_if [ "$staged" != "$(git -C "$T" rev-parse :Sample.swift)" ])"
pre "$T" "FOO=1 /usr/bin/git --no-pager commit -m t";    expect "assignment, full path, global option" 0 "SwiftLint passed"
pre "$T" 'git commit -m "Fix -a flag handling"';         expect "message containing -a" 0 "SwiftLint passed"
pre "$T" "git commit -ma";                               expect "-ma is -m a" 0 "SwiftLint passed"
pre "$T" "git commit --author 'A B <a@b>' -m t 2>&1";    expect "--author value and redirection" 0 "SwiftLint passed"
pre "$T" "git commit -q -F - <<'EOF'
Subject

Mentions \`git commit\` and \$(git add x); git commit -a
EOF"
expect "heredoc message with git commands in it" 0 "SwiftLint passed"
pre "$T" "git commit -m \"\$(cat <<'EOF'
Subject; with & and | and (parens)
EOF
)\""
expect "\$(cat <<EOF) message" 0 "SwiftLint passed"

mkrepo "$T"
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
pre "$T" 'result="$(git commit -m message)"';            expect "commit in quoted \$()" 2 "force_cast"
pre "$T" 'echo `git commit -m message`';                 expect "commit in backticks" 2 "force_cast"
pre "$T" 'echo "x `git commit -m m` y"';                 expect "backticks inside double quotes" 2 "force_cast"
pre "$T" "if true; then git commit -m test; fi";         expect "commit after then" 2 "force_cast"
pre "$T" "true || { git commit -m t; }";                 expect "commit in braces" 2 "force_cast"
pre "$T" "env FOO=1 git commit -m t";                    expect "env with an assignment" 2 "force_cast"

echo "== Claude hook: forms it blocks"
mkrepo "$O"
printf "$CLEAN" > "$O/Clean.swift"
git -C "$O" add Clean.swift
pre "$O" "git add Clean.swift && git commit -m t";       expect "add && commit" 2 "git add first"
pre "$O" "git rm -q x
git commit -m t";                                        expect "rm, newline, commit" 2 "git rm first"
pre "$O" "git cherry-pick -n abc123 && git commit -m t"; expect "cherry-pick -n && commit" 2 "git cherry-pick first"
pre "$O" "(git add x) && git commit -m t";               expect "add in a subshell" 2 "git add first"
pre "$O" "git fetch && git status && git commit -m t";   expect "read-only git commands before commit" 0 "SwiftLint passed"
pre "$O" "git commit -am t";                             expect "-am" 2 "aren't staged"
pre "$O" "git commit --all -m t";                        expect "--all" 2 "aren't staged"
pre "$O" "git commit Clean.swift -m t";                  expect "path" 2 "aren't staged"
pre "$O" "git commit -m t -- Clean.swift";               expect "-- path" 2 "aren't staged"
pre "$O" "git commit >commit.log -am message";           expect "redirection before -am" 2 "aren't staged"
pre "$O" "git commit -m x 2>&1 -a";                      expect "2>&1 then -a" 2 "aren't staged"
pre "$O" "git commit > commit.log -m x";                 expect "spaced redirection target" 0 "SwiftLint passed"
printf 'x\n' > "$O/>Clean.swift"
pre "$O" "git commit '>Clean.swift' -m test";            expect "quoted '>path' is a path" 2 "aren't staged"
rm -f "$O/>Clean.swift" "$O/commit.log"
pre "$O" "git --git-dir=$T/.git --work-tree=$T commit -m t"; expect "--git-dir" 2 "can't follow"
pre "$O" "GIT_INDEX_FILE=/tmp/x git commit -m t";        expect "GIT_INDEX_FILE" 2 "can't follow"
pre "$O" "export GIT_DIR=$T/.git; git commit -m t";      expect "export GIT_DIR" 2 "can't follow"
pre "$O" "env -u UNUSED git commit -m test";             expect "wrapper with options" 2 "env with options"
pre "$O" "git commit -m first && git add x && git commit -m second"; expect "two commits" 2 "2 times"
pre "$O" "git commit -m one && git push";                expect "commit then push" 0 "SwiftLint passed"

echo "== Claude hook: the repository the commit runs in"
pre "$O" "git -C $T commit -m t";                        expect "git -C" 2 "force_cast"
pre "$O" "cd $T && git commit -m t";                     expect "cd &&" 2 "force_cast"
pre "$T" "git commit -m t";                              expect "cwd" 2 "force_cast"
pre "$T" "(cd $O && true); git commit -m t";             expect "cd in a subshell doesn't leak" 2 "force_cast"
pre "$O" "(cd $T && git commit -m t)";                   expect "cd inside the same subshell" 2 "force_cast"
pre "" "git commit -m t";                                expect "empty cwd falls back to CLAUDE_PROJECT_DIR" 2 "force_cast"
git -C "$O" commit -qm base
W=$WORK/worktree
git -C "$O" worktree add -q "$W" -b wt 2>/dev/null
printf "$LINT_ERROR" > "$W/WorktreeBad.swift"
git -C "$W" add WorktreeBad.swift
pre "$W" "git commit -m t";                              expect "worktree checked against its own index" 2 "force_cast"
pre "$O" "git commit -m t";                              expect "main checkout unaffected by the worktree" 0 "No Swift files staged"

echo "== Shared checks"
mkrepo "$T"
printf "$LINT_ERROR" > "$T/Partial.swift"
git -C "$T" add Partial.swift
printf "$CLEAN" > "$T/Partial.swift"
pre "$T" "git commit -m t";                              expect "partly staged: staged error blocks" 2 "Partial.swift (staged)"
mkrepo "$T"
printf "$CLEAN" > "$T/Partial.swift"
git -C "$T" add Partial.swift
printf "$LINT_ERROR" > "$T/Partial.swift"
before=$(git -C "$T" rev-parse :Partial.swift)
pre "$T" "git commit -m t";                              expect "partly staged: unstaged error passes" 0 "not auto-formatted"
check "partly staged: index untouched" "$(yes_if [ "$before" = "$(git -C "$T" rev-parse :Partial.swift)" ])"
check "partly staged: warning sent to Claude as JSON" "$(yes_if sh -c 'printf "%s" "$1" | grep -q additionalContext' _ "$OUT")"

mkrepo "$T"
for f in "My File.swift" "Café.swift" "a[b].swift" "-dash.swift"; do printf "$UNFORMATTED" > "$T/$f"; done
printf 'x\n' > "$T/ab.swift"
git -C "$T" add -- "My File.swift" "Café.swift" ":(literal)a[b].swift" "-dash.swift"
pre "$T" "git commit -m t";                              expect "names with spaces, accents, brackets, a leading dash" 0 "SwiftLint passed"
formatted=$(for f in "My File.swift" "Café.swift" "a[b].swift" "-dash.swift"; do git -C "$T" show ":$f" | grep -c '^    let'; done | tr -d '\n')
check "all four formatted" "$(yes_if [ "$formatted" = 1111 ])"
check "ab.swift left unstaged" "$(yes_if sh -c '! git -C "$1" diff --cached --name-only | grep -qx ab.swift' _ "$T")"

mkrepo "$T"
printf "$CLEAN" > "$T/Old.swift"
git -C "$T" add Old.swift
git -C "$T" commit -qm base
git -C "$T" mv Old.swift New.swift
printf "$LINT_ERROR" >> "$T/New.swift"
git -C "$T" add New.swift
pre "$T" "git commit -m t";                              expect "renamed and edited file is linted" 2 "force_cast"

mkrepo "$T"
mkdir -p "$WORK/outside"
printf "$UNFORMATTED" > "$WORK/outside/Target.swift"
ln -s "$WORK/outside/Target.swift" "$T/Link.swift"
git -C "$T" add Link.swift
pre "$T" "git commit -m t";                              expect "symlinked Swift file skipped" 0 "is a symlink"
check "symlink target outside the repo untouched" "$(yes_if grep -q '^  let' "$WORK/outside/Target.swift")"

mkrepo "$T"
rm "$T/ci_scripts"
printf "$CLEAN" > "$T/Clean.swift"
git -C "$T" add Clean.swift
pre "$T" "git commit -m t";                              expect "missing parent config blocks" 2 "which is missing"

mkrepo "$T"
printf "$CLEAN" > "$T/Base.swift"
git -C "$T" add Base.swift
git -C "$T" commit -qm base
git -C "$T" checkout -qb incoming
printf "$UNFORMATTED" > "$T/Incoming.swift"
git -C "$T" add Incoming.swift
git -C "$T" commit -qm incoming
git -C "$T" checkout -q -
git -C "$T" merge -q --no-ff --no-commit incoming >/dev/null 2>&1
pre "$T" "git commit -m merge";                          expect "merge: file brought in unchanged is skipped" 0 "No Swift files staged"
check "merge: incoming file left as merged" "$(yes_if sh -c 'git -C "$1" show :Incoming.swift | grep -q "^  let"' _ "$T")"
git -C "$T" merge --abort

PATH_X86="$WORK/x86bin:$NOBREW:/opt/homebrew/bin"
mkdir -p "$WORK/x86bin"
printf '#!/bin/sh\necho "swiftlint: Bad CPU type in executable" >&2\nexit 126\n' > "$WORK/x86bin/swiftlint"
chmod +x "$WORK/x86bin/swiftlint"
mkrepo "$T"
printf "$CLEAN" > "$T/Clean.swift"
git -C "$T" add Clean.swift
OUT=$(jq -n --arg c "git commit -m t" --arg d "$T" '{tool_input: {command: $c}, cwd: $d}' |
    env PATH="$PATH_X86" CLAUDE_PROJECT_DIR="$T" /bin/bash "$H/pre-commit-lint.sh" 2>&1)
CODE=$?
expect "swiftlint that can't run blocks with a clear message" 2 "can't run"


echo "== Claude hook: pipelines, comments, functions, wrappers, options"
mkrepo "$T"
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
mkrepo "$O"
printf "$CLEAN" > "$O/Clean.swift"
git -C "$O" add Clean.swift
pre "$O" "cd $T | cat; git commit -m t";                  expect "cd in a pipeline doesn't leak" 0 "SwiftLint passed"
pre "$O" "git status | cd $T; git commit -m t";           expect "cd at the end of a pipeline doesn't leak" 0 "SwiftLint passed"
pre "$O" "cd $T || true; git commit -m t";                expect "cd before || still applies" 2 "force_cast"
pre "$O" "git status |& cat; git commit -m t";            expect "|& pipeline" 0 "SwiftLint passed"
pre "$O" "cd $T & wait; git commit -m t";                 expect "cd in a background command doesn't leak" 0 "SwiftLint passed"
pre "$O" "sleep 0 & cd $T && git commit -m t";            expect "cd after a background command applies" 2 "force_cast"
pre "$O" "cd $T # stay here; cd /tmp
git commit -m t";                                          expect "comment text isn't run" 2 "force_cast"
pre "$O" "git commit -m t # -a";                          expect "flag in a comment is ignored" 0 "SwiftLint passed"
pre "$O" "echo a#b; git commit -m t";                     expect "# inside a word isn't a comment" 0 "SwiftLint passed"
pre "$T" "function do_commit { git commit -m x; }; do_commit"; expect "commit inside a function keyword definition" 2 "force_cast"
pre "$T" "do_commit() { git commit -m x; }; do_commit";   expect "commit inside a name() definition" 2 "force_cast"
pre "$T" "/usr/bin/env git commit -m x";                  expect "path-qualified env" 2 "force_cast"
pre "$T" "/usr/bin/env -i git commit -m x";               expect "path-qualified env with options" 2 "env with options"
pre "$T" "timeout 60 git commit -m x";                    expect "timeout takes arguments" 2 "timeout with options"
pre "$T" "printf x | xargs git commit -m";                expect "xargs runs commands it reads" 2 "xargs with options"
pre "$O" "git commit --pathspec-from-fi=paths -m x";      expect "abbreviated --pathspec-from-file" 2 "aren't staged"
pre "$O" "git commit --al -m x";                          expect "abbreviated --all" 2 "aren't staged"
pre "$O" "git commit --mess 'two words'";                 expect "abbreviated --message takes a value" 0 "SwiftLint passed"
pre "$O" "git commit --untracked-files=no -m x";          expect "--untracked-files=no" 0 "SwiftLint passed"
pre "$O" "git commit -uno -m t";                          expect "-uno is -u no, not -o" 0 "SwiftLint passed"
pre "$O" "git commit -Skey -m t";                         expect "-S with an attached key" 0 "SwiftLint passed"

echo "== Shared checks: format failures, symlinked working copies, unusual names"
mkrepo "$T"
printf '{ this is not json\n' > "$T/.swift-format"
printf "$CLEAN" > "$T/Clean.swift"
git -C "$T" add Clean.swift
pre "$T" "git commit -m t";                                expect "malformed .swift-format blocks" 2 "swift-format couldn't format"
mkrepo "$T"
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
printf "$CLEAN" > "$WORK/outside/Clean.swift"
rm "$T/Bad.swift"
ln -s "$WORK/outside/Clean.swift" "$T/Bad.swift"
pre "$T" "git commit -m t";                                expect "staged file with a symlinked working copy is linted" 2 "Bad.swift (staged)"
mkrepo "$T"
for f in "$(printf 'Tab\tName.swift')" 'Quote"Name.swift' 'Back\slash.swift' "$(printf 'New\nLine.swift')"; do
    printf "$LINT_ERROR" > "$T/$f"
    git -C "$T" add -- ":(literal)$f"
done
pre "$T" "git commit -m t"
count=$(printf '%s' "$OUT" | grep -c 'force_cast')
check "tab, quote, backslash, and newline names are linted ($count)" "$(yes_if [ "$count" -ge 4 ])"

echo "== git pre-commit hook"
mkrepo "$T"
ln -s "$H/pre-commit.sh" "$T/.git/hooks/pre-commit"
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
OUT=$(env PATH="$NOBREW" git -C "$T" commit -qm bad 2>&1)
CODE=$?
expect "git hook blocks a lint error" 1 "force_cast"
git -C "$T" rm -q --cached Bad.swift
rm "$T/Bad.swift"
printf "$UNFORMATTED" > "$T/Sample.swift"
git -C "$T" add Sample.swift
OUT=$(env PATH="$NOBREW" git -C "$T" commit -qm sample 2>&1)
CODE=$?
expect "git hook allows a clean commit" 0
check "git hook formatted the committed file" "$(yes_if sh -c 'git -C "$1" show HEAD:Sample.swift | grep -q "^    let"' _ "$T")"
printf "$UNFORMATTED" > "$T/Sample.swift"
printf '// edit\n' >> "$T/Sample.swift"
OUT=$(env PATH="$NOBREW" git -C "$T" commit -qam edit 2>&1)
CODE=$?
expect "git hook with commit -a" 0
check "git hook formatted the -a commit" "$(yes_if sh -c 'git -C "$1" show HEAD:Sample.swift | grep -q "^    let"' _ "$T")"

echo "== edit hook"
mkrepo "$T"
printf "$LINT_ERROR" > "$T/Bad.swift"
post "$T/Bad.swift"
check "issues are JSON additionalContext" "$(yes_if sh -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | contains(\"force_cast\")" >/dev/null' _ "$OUT")"
printf "$CLEAN" > "$T/Clean.swift"
post "$T/Clean.swift"
expect "clean file prints plain pass lines" 0 "swiftlint (Clean.swift): pass"
check "clean file prints no JSON" "$(yes_if sh -c '! printf "%s" "$1" | grep -q hookSpecificOutput' _ "$OUT")"
mkrepo "$O"
printf 'disabled_rules: [force_cast]\n' > "$O/.swiftlint.local.yml"
printf "$LINT_ERROR" > "$O/Bad.swift"
post "$O/Bad.swift"
expect "uses the edited file's repository config" 0 "swiftlint (Bad.swift): pass"
OUT=$(jq -n --arg f "$T/Clean.swift" '{tool_input: {file_path: $f}}' |
    env PATH="$PATH_X86" CLAUDE_PROJECT_DIR="$T" /bin/bash "$H/post-edit-lint.sh" 2>/dev/null)
check "swiftlint that can't run is reported, not a pass" "$(yes_if sh -c 'printf "%s" "$1" | grep -q "can.t run" && ! printf "%s" "$1" | grep -q "swiftlint (Clean.swift): pass"' _ "$OUT")"
rm "$T/ci_scripts"
post "$T/Clean.swift"
check "missing parent config is reported" "$(yes_if sh -c 'printf "%s" "$1" | grep -q "which is missing"' _ "$OUT")"

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
