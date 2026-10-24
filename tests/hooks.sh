#!/bin/bash
#
# hooks.sh - Tests for the git hooks (pre-commit.sh, post-commit.sh), their
# installer, the Claude Code shims, and post-edit-lint.sh, run against
# throwaway repositories.
#
# Usage: tests/hooks.sh
# Requires git, jq, swift-format (Xcode toolchain), and swiftlint. Runs with
# the system bash (3.2 on macOS) like the hooks themselves.
#

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
H=$ROOT/hooks
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ci-scripts-hook-tests.XXXXXX")
WORK=$(cd -P "$WORK" && pwd)
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
# from ci_scripts/.swiftlint.yml, as a consuming project has. With
# "hooks", the git hooks are installed.
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
    if [ "$2" = hooks ]; then
        (cd "$1" && env -u CLAUDE_PROJECT_DIR "$H/install-git-hooks.sh" >/dev/null)
    fi
}
# Commit in repository $1 with git commit arguments $2...; sets OUT and CODE
commit() {
    local repo=$1
    shift
    OUT=$(env PATH="$NOBREW" git -C "$repo" commit -q "$@" 2>&1)
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
committed() { git -C "$1" show "HEAD:$2" 2>/dev/null; }

T=$WORK/main
O=$WORK/other

echo "== install-git-hooks.sh"
mkrepo "$T"
OUT=$(cd "$T" && env -u CLAUDE_PROJECT_DIR "$H/install-git-hooks.sh"); CODE=$?
expect "fresh install reports both hooks" 0 "Installed"
check "pre-commit links to pre-commit.sh" "$(yes_if [ "$(readlink "$T/.git/hooks/pre-commit")" = "$H/pre-commit.sh" ])"
check "post-commit links to post-commit.sh" "$(yes_if [ "$(readlink "$T/.git/hooks/post-commit")" = "$H/post-commit.sh" ])"
OUT=$(cd "$T" && env -u CLAUDE_PROJECT_DIR "$H/install-git-hooks.sh"); CODE=$?
check "running again is silent" "$(yes_if [ -z "$OUT" ])"
OUT=$(printf '{"source":"startup"}' | env CLAUDE_PROJECT_DIR="$T" "$H/install-git-hooks.sh" --claude); CODE=$?
check "--claude with nothing to report prints nothing" "$(yes_if [ -z "$OUT" ])"
# A project with its own copy of the scripts, as a submodule checkout has
mkcopy() {
    mkrepo "$1"
    rm "$1/ci_scripts"
    mkdir -p "$1/ci_scripts"
    cp -R "$H" "$1/ci_scripts/hooks"
    cp "$ROOT/.swiftlint.yml" "$1/ci_scripts/"
}
mkcopy "$T"
C=$T/ci_scripts/hooks
(cd "$T" && env -u CLAUDE_PROJECT_DIR "$C/install-git-hooks.sh" >/dev/null)
ln -sf /old/clone/ci_scripts/hooks/pre-commit.sh "$T/.git/hooks/pre-commit"
OUT=$(cd "$T" && env -u CLAUDE_PROJECT_DIR "$C/install-git-hooks.sh"); CODE=$?
expect "a link from a moved clone is updated" 0 "Updated"
check "  to this copy" "$(yes_if [ "$(readlink "$T/.git/hooks/pre-commit")" = "$C/pre-commit.sh" ])"
rm "$T/.git/hooks/pre-commit"
printf '#!/bin/sh
echo other tool
' > "$T/.git/hooks/pre-commit"
chmod +x "$T/.git/hooks/pre-commit"
OUT=$(printf '{}' | env CLAUDE_PROJECT_DIR="$T" "$C/install-git-hooks.sh" --claude); CODE=$?
check "a foreign hook is left alone" "$(yes_if grep -q "other tool" "$T/.git/hooks/pre-commit")"
check "  and reported to Claude as JSON" "$(yes_if sh -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | contains(\"left alone\")" >/dev/null' _ "$OUT")"
check "  with the line to call ours from it" "$(yes_if sh -c 'printf "%s" "$1" | grep -q "ci_scripts/hooks/pre-commit.sh"' _ "$OUT")"
check "post-commit is still installed beside it" "$(yes_if [ -L "$T/.git/hooks/post-commit" ])"
printf '#!/bin/sh\necho other tool\n"$(git rev-parse --show-toplevel)/ci_scripts/hooks/pre-commit.sh" || exit 1\n' > "$T/.git/hooks/pre-commit"
OUT=$(printf '{}' | env CLAUDE_PROJECT_DIR="$T" "$C/install-git-hooks.sh" --claude); CODE=$?
check "a hook that already calls ours isn't reported" "$(yes_if [ -z "$OUT" ])"
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
commit "$T" -m chained;                                  expect "  and the chained call blocks a lint error" 1 "force_cast"
mkrepo "$T"
git -C "$T" config core.hooksPath custom-hooks
OUT=$(cd "$T" && env -u CLAUDE_PROJECT_DIR "$H/install-git-hooks.sh"); CODE=$?
check "core.hooksPath is used" "$(yes_if [ -L "$T/custom-hooks/pre-commit" ])"
mkrepo "$T"
printf "$CLEAN" > "$T/Base.swift"
git -C "$T" add Base.swift
git -C "$T" commit -qm base
git -C "$T" worktree add -q "$WORK/wt" -b wt 2>/dev/null
OUT=$(cd "$WORK/wt" && env -u CLAUDE_PROJECT_DIR "$H/install-git-hooks.sh"); CODE=$?
check "from a worktree, installs into the shared hooks" "$(yes_if [ -L "$T/.git/hooks/pre-commit" ])"
OUT=$(cd "$WORK" && env -u CLAUDE_PROJECT_DIR "$H/install-git-hooks.sh"); CODE=$?
expect "outside a repository does nothing" 0

echo "== pre-commit.sh (git pre-commit hook)"
mkrepo "$T" hooks
printf "$UNFORMATTED" > "$T/Sample.swift"
git -C "$T" add Sample.swift
commit "$T" -m sample;                                   expect "clean commit allowed" 0
check "committed file formatted" "$(yes_if sh -c 'git -C "$1" show HEAD:Sample.swift | grep -q "^    let"' _ "$T")"
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
commit "$T" -m bad;                                      expect "lint error blocks" 1 "force_cast"
git -C "$T" rm -q --cached Bad.swift
rm "$T/Bad.swift"
printf "$UNFORMATTED" > "$T/Sample.swift"
printf '// edit\n' >> "$T/Sample.swift"
commit "$T" -am edit;                                    expect "commit -a allowed" 0
check "commit -a formatted" "$(yes_if sh -c 'git -C "$1" show HEAD:Sample.swift | grep -q "^    let"' _ "$T")"
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
commit "$T" -m path;                                     expect "lint error staged by git add blocks" 1 "force_cast"
git -C "$T" rm -q --cached Bad.swift
rm "$T/Bad.swift"

mkrepo "$T" hooks
printf "$LINT_ERROR" > "$T/Partial.swift"
git -C "$T" add Partial.swift
printf "$CLEAN" > "$T/Partial.swift"
commit "$T" -m t;                                        expect "partly staged: staged error blocks" 1 "Partial.swift (staged)"
mkrepo "$T" hooks
printf "$CLEAN" > "$T/Partial.swift"
git -C "$T" add Partial.swift
printf "$LINT_ERROR" > "$T/Partial.swift"
commit "$T" -m t;                                        expect "partly staged: unstaged error passes" 0
check "partly staged: only the staged content is committed" "$(yes_if [ "$(committed "$T" Partial.swift)" = "let value = 1" ])"
check "partly staged: working copy untouched" "$(yes_if grep -q 'as! Int' "$T/Partial.swift")"

mkrepo "$T" hooks
for f in "My File.swift" "Café.swift" "a[b].swift" "-dash.swift" "$(printf 'Tab\tName.swift')"; do printf "$UNFORMATTED" > "$T/$f"; done
printf 'x\n' > "$T/ab.swift"
git -C "$T" add -- "My File.swift" "Café.swift" ":(literal)a[b].swift" "-dash.swift" "$(printf ':(literal)Tab\tName.swift')"
commit "$T" -m names;                                    expect "unusual names allowed" 0
formatted=$(for f in "My File.swift" "Café.swift" "a[b].swift" "-dash.swift" "$(printf 'Tab\tName.swift')"; do committed "$T" "$f" | grep -c '^    let'; done | tr -d '\n')
check "unusual names formatted" "$(yes_if [ "$formatted" = 11111 ])"
check "ab.swift left out" "$(yes_if sh -c '! git -C "$1" ls-files --error-unmatch ab.swift >/dev/null 2>&1' _ "$T")"

mkrepo "$T" hooks
printf "$CLEAN" > "$T/Old.swift"
git -C "$T" add Old.swift
commit "$T" -m base
git -C "$T" mv Old.swift New.swift
printf "$LINT_ERROR" >> "$T/New.swift"
git -C "$T" add New.swift
commit "$T" -m rename;                                   expect "renamed and edited file is linted" 1 "force_cast"

mkrepo "$T" hooks
mkdir -p "$WORK/outside"
printf "$UNFORMATTED" > "$WORK/outside/Target.swift"
ln -s "$WORK/outside/Target.swift" "$T/Link.swift"
git -C "$T" add Link.swift
commit "$T" -m link;                                     expect "symlinked Swift file skipped" 0 "is a symlink"
check "symlink target untouched" "$(yes_if grep -q '^  let' "$WORK/outside/Target.swift")"

mkrepo "$T" hooks
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
printf "$CLEAN" > "$WORK/outside/Clean.swift"
rm "$T/Bad.swift"
ln -s "$WORK/outside/Clean.swift" "$T/Bad.swift"
commit "$T" -m t;                                        expect "staged file with a symlinked working copy is linted" 1 "Bad.swift (staged)"

mkrepo "$T" hooks
rm "$T/ci_scripts"
mkdir -p "$T/ci_scripts"
ln -s "$H" "$T/ci_scripts/hooks"
printf "$CLEAN" > "$T/Clean.swift"
git -C "$T" add Clean.swift
commit "$T" -m t;                                        expect "missing parent config blocks" 1 "which is missing"

mkrepo "$T" hooks
printf '{ this is not json\n' > "$T/.swift-format"
printf "$CLEAN" > "$T/Clean.swift"
git -C "$T" add Clean.swift
commit "$T" -m t;                                        expect "malformed .swift-format blocks" 1 "swift-format couldn't format"

mkrepo "$T" hooks
printf "$CLEAN" > "$T/Base.swift"
git -C "$T" add Base.swift
commit "$T" -m base
git -C "$T" checkout -qb incoming
printf "$UNFORMATTED" > "$T/Incoming.swift"
git -C "$T" add Incoming.swift
commit "$T" --no-verify -m incoming 2>/dev/null
git -C "$T" checkout -q -
git -C "$T" merge -q --no-ff --no-commit incoming >/dev/null 2>&1
commit "$T" -m merge;                                    expect "merge: file brought in unchanged is skipped" 0
check "merge: incoming file left as merged" "$(yes_if sh -c 'git -C "$1" show HEAD:Incoming.swift | grep -q "^  let"' _ "$T")"

mkdir -p "$WORK/x86bin"
printf '#!/bin/sh\necho "swiftlint: Bad CPU type in executable" >&2\nexit 126\n' > "$WORK/x86bin/swiftlint"
chmod +x "$WORK/x86bin/swiftlint"
mkrepo "$T" hooks
printf "$CLEAN" > "$T/Clean.swift"
git -C "$T" add Clean.swift
OUT=$(env PATH="$WORK/x86bin:$NOBREW:/opt/homebrew/bin" git -C "$T" commit -qm t 2>&1); CODE=$?
expect "swiftlint that can't run blocks with a clear message" 1 "can't run"

echo "== post-commit.sh (catches commits pre-commit.sh didn't check)"
mkrepo "$T" hooks
printf "$CLEAN" > "$T/Clean.swift"
git -C "$T" add Clean.swift
commit "$T" -m clean;                                    expect "a checked commit is allowed" 0
check "  with no post-commit warning" "$(yes_if sh -c '! printf "%s" "$1" | grep -q "wasn.t checked"' _ "$OUT")"
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
commit "$T" --no-verify -m bypass;                       expect "--no-verify with a lint error: commit made, warning shown" 0 "wasn't checked"
check "  names the lint error" "$(yes_if sh -c 'printf "%s" "$1" | grep -q "Bad.swift.*force_cast"' _ "$OUT")"
printf "$UNFORMATTED" > "$T/Unformatted.swift"
git -C "$T" add Unformatted.swift
commit "$T" -n -m bypass2;                               expect "-n with an unformatted file warns" 0 "Indentation"
printf "$CLEAN" > "$T/Clean2.swift"
git -C "$T" add Clean2.swift
commit "$T" --no-verify -m bypass3;                      expect "--no-verify with clean files prints nothing" 0
check "  (no warning)" "$(yes_if [ -z "$OUT" ])"
printf 'notes\n' > "$T/notes.txt"
git -C "$T" add notes.txt
commit "$T" --no-verify -m notes;                        expect "--no-verify without Swift files prints nothing" 0
check "  (no warning)" "$(yes_if [ -z "$OUT" ])"
git -C "$T" checkout -qb picked
printf "$LINT_ERROR" > "$T/Picked.swift"
git -C "$T" add Picked.swift
commit "$T" --no-verify -m picked 2>/dev/null
git -C "$T" checkout -q -
OUT=$(env PATH="$NOBREW" git -C "$T" cherry-pick picked 2>&1); CODE=$?
expect "cherry-pick of an unchecked lint error warns" 0 "wasn't checked"

echo "== pre-commit-lint.sh (compatibility shim)"
mkrepo "$T"
for c in "git commit -m x" "rg 'git commit'" "ls"; do
    OUT=$(jq -n --arg c "$c" --arg d "$T" '{tool_input: {command: $c}, cwd: $d}' |
        env CLAUDE_PROJECT_DIR="$T" /bin/bash "$H/pre-commit-lint.sh" 2>&1); CODE=$?
    expect "allows: $c" 0
done
check "and installs the git hooks" "$(yes_if [ -L "$T/.git/hooks/pre-commit" ])"

echo "== post-edit-lint.sh"
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
    env PATH="$WORK/x86bin:$NOBREW:/opt/homebrew/bin" CLAUDE_PROJECT_DIR="$T" /bin/bash "$H/post-edit-lint.sh" 2>/dev/null)
check "swiftlint that can't run is reported, not a pass" "$(yes_if sh -c 'printf "%s" "$1" | grep -q "can.t run" && ! printf "%s" "$1" | grep -q "swiftlint (Clean.swift): pass"' _ "$OUT")"
rm "$T/ci_scripts"
post "$T/Clean.swift"
check "missing parent config is reported" "$(yes_if sh -c 'printf "%s" "$1" | grep -q "which is missing"' _ "$OUT")"

echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
