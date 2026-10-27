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
        (cd "$1" && env -u CLAUDE_PROJECT_DIR ci_scripts/hooks/install-git-hooks.sh >/dev/null)
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
# Run the installer the way a project does, from its ci_scripts: install [args]; sets OUT and CODE
install() {
    OUT=$(cd "$T" && env -u CLAUDE_PROJECT_DIR ci_scripts/hooks/install-git-hooks.sh "$@" < /dev/null); CODE=$?
}
mkrepo "$T"
install
expect "fresh setup creates the tracked hooks" 0 "Created .githooks/pre-commit."
check "  and sets core.hooksPath to .githooks" "$(yes_if [ "$(git -C "$T" config core.hooksPath)" = .githooks ])"
check "  both executable" "$(yes_if [ -x "$T/.githooks/pre-commit" -a -x "$T/.githooks/post-commit" ])"
check "  calling the scripts by their path in the project" "$(yes_if grep -qF '/ci_scripts/hooks/pre-commit.sh"' "$T/.githooks/pre-commit")"
check "  and asks for them to be committed" "$(yes_if sh -c 'printf "%s" "$1" | grep -qF "Commit .githooks/pre-commit .githooks/post-commit"' _ "$OUT")"
OUT=$(printf '{"source":"startup"}' | env CLAUDE_PROJECT_DIR="$T" "$T/ci_scripts/hooks/install-git-hooks.sh" --claude); CODE=$?
check "--claude reports uncommitted hooks as JSON" "$(yes_if sh -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | contains(\"Commit .githooks\")" >/dev/null' _ "$OUT")"
git -C "$T" add .githooks
commit "$T" -m hooks
install
check "running again after committing them is silent" "$(yes_if [ -z "$OUT" ])"
OUT=$(printf '{"source":"startup"}' | env CLAUDE_PROJECT_DIR="$T" "$T/ci_scripts/hooks/install-git-hooks.sh" --claude); CODE=$?
check "--claude with nothing to report prints nothing" "$(yes_if [ -z "$OUT" ])"
mkdir -p "$T/sub"
OUT=$(cd "$T/sub" && env -u CLAUDE_PROJECT_DIR ../ci_scripts/hooks/install-git-hooks.sh); CODE=$?
check "from a subdirectory, silent too" "$(yes_if [ -z "$OUT" ])"

mkrepo "$T"
printf '#!/bin/sh\necho other tool\n' > "$T/.git/hooks/pre-commit"
chmod +x "$T/.git/hooks/pre-commit"
OUT=$(printf '{}' | env CLAUDE_PROJECT_DIR="$T" "$T/ci_scripts/hooks/install-git-hooks.sh" --claude); CODE=$?
check "a hook in .git/hooks is left alone" "$(yes_if grep -q "other tool" "$T/.git/hooks/pre-commit")"
check "  without setting core.hooksPath, which would turn it off" "$(yes_if [ -z "$(git -C "$T" config core.hooksPath)" ])"
check "  reported to Claude as JSON" "$(yes_if sh -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | contains(\"stop running these hooks in .git/hooks: pre-commit\")" >/dev/null' _ "$OUT")"

mkrepo "$T"
git -C "$T" config core.hooksPath custom-hooks
install
expect "core.hooksPath set elsewhere is reported" 0 "core.hooksPath is custom-hooks"
check "  and left as it is" "$(yes_if [ "$(git -C "$T" config core.hooksPath)" = custom-hooks -a ! -e "$T/.githooks" ])"
mkdir -p "$T/custom-hooks"
for name in pre-commit post-commit; do
    printf '#!/bin/sh\necho other tool\n"$(git rev-parse --show-toplevel)/ci_scripts/hooks/%s.sh" || exit 1\n' "$name" > "$T/custom-hooks/$name"
    chmod +x "$T/custom-hooks/$name"
done
install
check "hooks there that call ours aren't reported" "$(yes_if [ -z "$OUT" ])"
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
commit "$T" -m chained;                                  expect "  and the chained call blocks a lint error" 1 "force_cast"

mkrepo "$T"
mkdir -p "$T/.githooks"
printf '#!/bin/sh\necho mine\n' > "$T/.githooks/pre-commit"
chmod +x "$T/.githooks/pre-commit"
install
expect "a .githooks hook of the project's own is reported" 0 ".githooks/pre-commit doesn't run the Swift checks"
check "  and kept as it was" "$(yes_if sh -c 'grep -q mine "$1" && ! grep -q ci_scripts "$1"' _ "$T/.githooks/pre-commit")"
check "  with post-commit created beside it" "$(yes_if [ -x "$T/.githooks/post-commit" ])"

mkdir -p "$WORK/elsewhere"
cp -R "$H" "$WORK/elsewhere/hooks"
mkrepo "$T"
OUT=$(cd "$T" && env -u CLAUDE_PROJECT_DIR "$WORK/elsewhere/hooks/install-git-hooks.sh"); CODE=$?
expect "scripts outside the repository are reported" 0 "isn't inside this repository"
check "  and nothing is set up" "$(yes_if [ ! -e "$T/.githooks" -a -z "$(git -C "$T" config core.hooksPath)" ])"

# A project with its own copy of the scripts, as a submodule checkout has
mkcopy() {
    mkrepo "$1"
    rm "$1/ci_scripts"
    mkdir -p "$1/ci_scripts"
    cp -R "$H" "$1/ci_scripts/hooks"
    cp "$ROOT/.swiftlint.yml" "$1/ci_scripts/"
}
mkcopy "$T"
(cd "$T" && env -u CLAUDE_PROJECT_DIR ci_scripts/hooks/install-git-hooks.sh >/dev/null)
git -C "$T" add -A
commit "$T" -m setup
git -C "$T" worktree add -q "$WORK/wt" -b wt 2>/dev/null
printf '\necho "worktree copy ran"\n' >> "$WORK/wt/ci_scripts/hooks/pre-commit.sh"
printf "$CLEAN" > "$WORK/wt/Clean.swift"
git -C "$WORK/wt" add Clean.swift
commit "$WORK/wt" -m clean;                              expect "a worktree runs its own copy of the checks" 0 "worktree copy ran"
printf "$LINT_ERROR" > "$WORK/wt/Bad.swift"
git -C "$WORK/wt" add Bad.swift
commit "$WORK/wt" -m bad;                                expect "  and blocks a lint error there" 1 "force_cast"
git -C "$T" worktree remove --force "$WORK/wt"
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
commit "$T" -m bad;                                      expect "removing the worktree leaves the main checkout's checks working" 1 "force_cast"

mkrepo "$T" hooks
rm "$T/ci_scripts"
printf "$CLEAN" > "$T/Clean.swift"
git -C "$T" add Clean.swift
commit "$T" -m t;                                        expect "a missing ci_scripts blocks with a clear message" 1 "git submodule update --init"
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
printf "$LINT_ERROR" > "$T/Resolved.swift"
git -C "$T" add Resolved.swift
commit "$T" --no-verify -m merge;                        expect "merge finished with --no-verify: a new lint error warns" 0 "wasn't checked"
check "  names it" "$(yes_if sh -c 'printf "%s" "$1" | grep -q "Resolved.swift.*force_cast"' _ "$OUT")"
check "  but not the file brought in unchanged" "$(yes_if sh -c '! printf "%s" "$1" | grep -q "Incoming.swift"' _ "$OUT")"
mkrepo "$T" hooks
printf '{ this is not json\n' > "$T/.swift-format"
printf "$CLEAN" > "$T/Clean.swift"
git -C "$T" add Clean.swift
commit "$T" --no-verify -m t;                            expect "--no-verify with a malformed .swift-format warns" 0 "swift-format couldn't check Clean.swift"

mkrepo "$T" hooks
printf "$LINT_ERROR" > "$T/Bad.swift"
git -C "$T" add Bad.swift
commit "$T" --no-verify -m root;                         expect "first commit with --no-verify warns" 0 "wasn't checked"
printf "$CLEAN" > "$T/Bad.swift"
git -C "$T" add Bad.swift
commit "$T" -m fixed
printf "$LINT_ERROR" > "$T/Amended.swift"
git -C "$T" add Amended.swift
commit "$T" --amend --no-verify --no-edit;               expect "amend with --no-verify warns" 0 "Amended.swift"
git -C "$T" checkout -qb topic
printf "$LINT_ERROR" > "$T/Topic.swift"
git -C "$T" add Topic.swift
commit "$T" --no-verify -m topic 2>/dev/null
git -C "$T" checkout -q -
printf "$CLEAN" > "$T/Main.swift"
git -C "$T" add Main.swift
commit "$T" -m main
git -C "$T" checkout -q topic
OUT=$(env PATH="$NOBREW" git -C "$T" rebase -q - 2>&1); CODE=$?
expect "rebase replays without warnings" 0
check "  (no warning)" "$(yes_if sh -c '! printf "%s" "$1" | grep -q "wasn.t checked"' _ "$OUT")"
git -C "$T" checkout -q -
git -C "$T" merge -q --no-ff --no-commit topic >/dev/null 2>&1
printf "$LINT_ERROR" > "$T/Resolved.swift"
git -C "$T" add Resolved.swift
commit "$T" -m merge;                                    expect "merge with a new lint error is blocked by pre-commit" 1 "Resolved.swift"
check "  but not for the file brought in unchanged" "$(yes_if sh -c '! printf "%s" "$1" | grep -q "Topic.swift"' _ "$OUT")"
git -C "$T" merge --abort

rm -rf "$T"
mkdir -p "$T"
if git -C "$T" init -q --object-format=sha256 2>/dev/null; then
    git -C "$T" config user.email test@example.com
    git -C "$T" config user.name Test
    git -C "$T" config commit.gpgsign false
    printf '{ "version": 1, "indentation": { "spaces": 4 }, "lineLength": 1000 }\n' > "$T/.swift-format"
    printf 'parent_config: ci_scripts/.swiftlint.yml\n' > "$T/.swiftlint.local.yml"
    ln -s "$ROOT" "$T/ci_scripts"
    (cd "$T" && ci_scripts/hooks/install-git-hooks.sh >/dev/null)
    printf "$LINT_ERROR" > "$T/Bad.swift"
    git -C "$T" add Bad.swift
    commit "$T" --no-verify -m root;                     expect "SHA-256 repository: first commit with --no-verify warns" 0 "force_cast"
    printf "$UNFORMATTED" > "$T/Sample.swift"
    git -C "$T" add Sample.swift
    commit "$T" -m sample;                               expect "SHA-256 repository: pre-commit formats" 0
    check "  committed file formatted" "$(yes_if sh -c 'git -C "$1" show HEAD:Sample.swift | grep -q "^    let"' _ "$T")"
fi

echo "== pre-commit-lint.sh (compatibility shim)"
# Run the shim as Claude Code does before a Bash command: shim <session id> [command]
shim() {
    OUT=$(jq -n --arg s "$1" --arg c "${2:-git commit -m x}" '{session_id: $s, tool_input: {command: $c}}' |
        env CLAUDE_PROJECT_DIR="$T" /bin/bash "$T/ci_scripts/hooks/pre-commit-lint.sh" 2>&1); CODE=$?
}
mkrepo "$T"
shim s1
expect "allows the command" 0
check "  and sets up the git hooks" "$(yes_if [ "$(git -C "$T" config core.hooksPath)" = .githooks -a -x "$T/.githooks/pre-commit" ])"
check "  telling Claude what needs action, as PreToolUse context without a decision" "$(yes_if sh -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput | .hookEventName == \"PreToolUse\" and (.additionalContext | contains(\"Commit .githooks\")) and .permissionDecision == null" >/dev/null' _ "$OUT")"
shim s1
check "  once per session" "$(yes_if [ -z "$OUT" ])"
shim s2
check "  and again in a new session" "$(yes_if sh -c 'printf "%s" "$1" | grep -q "Commit .githooks"' _ "$OUT")"
git -C "$T" add .githooks
commit "$T" -m hooks
for c in "git commit -m x" "rg 'git commit'" "ls"; do
    shim s3 "$c"
    expect "allows: $c" 0
    check "  quietly once set up" "$(yes_if [ -z "$OUT" ])"
done

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
