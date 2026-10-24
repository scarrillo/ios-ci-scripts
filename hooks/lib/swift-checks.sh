#!/bin/bash
#
# swift-checks.sh - Shared swift-format and SwiftLint checks for the hooks
#
# Sourced by pre-commit-lint.sh (Claude Code), pre-commit.sh (git), and
# post-edit-lint.sh. Requires Bash 3.2 or newer. Messages go to stderr.
#

# Sessions started outside a login shell may lack Apple Silicon Homebrew.
# Add it first so an x86_64 binary in /usr/local/bin, which can't run
# without Rosetta, doesn't win. A PATH that already lists it is kept as is.
swift_checks_path() {
    if [ -d /opt/homebrew/bin ]; then
        case ":$PATH:" in
            *:/opt/homebrew/bin:*) ;;
            *) export PATH="/opt/homebrew/bin:$PATH" ;;
        esac
    fi
}

# swift-format ships with Xcode's toolchain. When the Command Line Tools are
# selected and lack it, use Xcode's toolchain if it's installed. A selection
# that works, or an explicit DEVELOPER_DIR, is kept.
swift_checks_toolchain() {
    if swift format --version >/dev/null 2>&1 || [ -n "${DEVELOPER_DIR:-}" ]; then
        return 0
    fi
    case "$(xcode-select -p 2>/dev/null)" in
        */CommandLineTools)
            if [ -d /Applications/Xcode.app/Contents/Developer ]; then
                export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
            fi ;;
    esac
}

# Set LINT_ARGS to the SwiftLint config for the current directory
swift_checks_lint_args() {
    if [ -f ".swiftlint.local.yml" ]; then
        LINT_ARGS=(--config .swiftlint.local.yml)
    elif [ -f "ci_scripts/.swiftlint.yml" ]; then
        LINT_ARGS=(--config ci_scripts/.swiftlint.yml)
    else
        LINT_ARGS=()
    fi
}

# Print the parent_config of .swiftlint.local.yml when that file is missing,
# for example when the ci_scripts submodule isn't initialized. SwiftLint only
# warns and lints without the parent's rules.
swift_checks_missing_parent() {
    local parent
    [ -f .swiftlint.local.yml ] || return 1
    parent=$(sed -n 's/^parent_config:[[:space:]]*//p' .swiftlint.local.yml | head -n 1 |
        sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']\$//")
    case "$parent" in
        "" | http://* | https://*) return 1 ;;
    esac
    if [ -e "$parent" ]; then
        return 1
    fi
    printf '%s\n' "$parent"
}

# Report swift-format or SwiftLint missing, or a swiftlint that can't run.
# Returns 1 when a tool is unusable.
swift_checks_tools() {
    local usable=0
    if ! swift format --version >/dev/null 2>&1; then
        echo "ERROR: swift-format not available — requires Xcode toolchain (Swift 5.9+)" >&2
        usable=1
    fi
    if ! which swiftlint >/dev/null 2>&1; then
        echo "ERROR: swiftlint not found — install with: brew install swiftlint" >&2
        usable=1
    elif ! swiftlint version >/dev/null 2>&1; then
        echo "ERROR: $(which swiftlint) can't run (built for another CPU architecture?)" >&2
        usable=1
    fi
    return $usable
}

# Print the staged Swift files to check, each ending in NUL: added, copied,
# modified, or renamed. Skips staged symlinks, and during a merge, files whose
# staged content matches a merge parent (brought in unchanged by the merge; a
# heuristic, not a detector for hand-resolved conflicts).
swift_checks_staged_files() {
    local file parent merge_head inherited
    merge_head=$(git rev-parse --git-path MERGE_HEAD 2>/dev/null)
    git diff --cached --name-only -z --diff-filter=ACMR |
        while IFS= read -r -d '' file; do
            case "$file" in
                *.swift) ;;
                *) continue ;;
            esac
            if git ls-files -s -- ":(literal)$file" | grep -q '^120000 '; then
                echo "warning: $file is a symlink, so it was not formatted or linted." >&2
                continue
            fi
            if [ -n "$merge_head" ] && [ -f "$merge_head" ]; then
                inherited=false
                while IFS= read -r parent; do
                    if git diff --no-ext-diff --no-textconv --cached --quiet "$parent" -- ":(literal)$file" 2>/dev/null; then
                        inherited=true
                        break
                    fi
                done < "$merge_head"
                if $inherited; then
                    continue
                fi
            fi
            printf '%s\0' "$file"
        done
}

# A staged file that also has unstaged changes: its working copy isn't what gets committed
swift_checks_partly_staged() {
    ! git diff --no-ext-diff --no-textconv --quiet -- ":(literal)$1"
}

# Format and lint the staged Swift files of the repository in the current
# directory. Returns 1 when the commit should be blocked.
swift_checks_staged() {
    local file output parent lint_failed=false lint_output=""
    local staged_files=() full_files=() partial_files=()

    swift_checks_path
    swift_checks_toolchain
    if ! swift_checks_tools; then
        echo "Commit blocked: required lint tools are missing." >&2
        return 1
    fi

    while IFS= read -r -d '' file; do
        staged_files+=("$file")
    done < <(swift_checks_staged_files)
    if [ ${#staged_files[@]} -eq 0 ]; then
        echo "No Swift files staged, skipping lint." >&2
        return 0
    fi

    if parent=$(swift_checks_missing_parent); then
        echo "Commit blocked: .swiftlint.local.yml inherits from $parent, which is missing, so SwiftLint would skip its rules." >&2
        echo "If it comes from a submodule, run: git submodule update --init" >&2
        return 1
    fi

    # Run swift-format on staged files (auto-fix in place, then re-stage).
    # Re-staging adds the whole file, so a file that also has unstaged changes
    # is left unformatted: re-staging it would commit those changes too.
    if [ -f ".swift-format" ]; then
        echo "Running swift-format on staged files..." >&2
        for file in "${staged_files[@]}"; do
            if [ ! -f "$file" ]; then
                continue
            fi
            if swift_checks_partly_staged "$file"; then
                echo "warning: $file has unstaged changes, so it was not auto-formatted." >&2
                continue
            fi
            if ! output=$(swift format format --configuration .swift-format --in-place -- "$file" 2>&1); then
                printf '%s\n' "$output" >&2
                echo "Commit blocked: swift-format couldn't format $file." >&2
                return 1
            fi
            if [ -n "$output" ]; then
                printf '%s\n' "$output" >&2
            fi
            git add -- ":(literal)$file"
        done
    fi

    # Run SwiftLint on staged files only (warnings allowed, errors block)
    echo "Running SwiftLint on staged files..." >&2
    swift_checks_lint_args

    for file in "${staged_files[@]}"; do
        if swift_checks_partly_staged "$file"; then
            partial_files+=("$file")
        else
            full_files+=("$file")
        fi
    done

    if [ ${#full_files[@]} -gt 0 ]; then
        output=$(swiftlint lint "${LINT_ARGS[@]}" -- "${full_files[@]}" 2>&1) || lint_failed=true
        lint_output+="$output"$'\n'
    fi
    # Lint what gets committed: the staged content, not the working copy.
    # Standard input doesn't apply the config's `excluded` paths.
    for file in "${partial_files[@]}"; do
        output=$(git cat-file blob ":$file" | swiftlint lint --use-stdin "${LINT_ARGS[@]}" 2>&1) || lint_failed=true
        lint_output+="${output//<nopath>/$file (staged)}"$'\n'
    done

    if $lint_failed; then
        echo "$lint_output" >&2
        echo "SwiftLint found errors. Please fix before committing." >&2
        return 1
    fi
    echo "SwiftLint passed." >&2
    return 0
}

# Where pre-commit.sh records the staged tree it passed, so post-commit.sh
# can tell a checked commit from one made with git commit --no-verify
swift_checks_marker() {
    git rev-parse --git-path swift-checks-passed
}

# Check the Swift files commit $1 added or changed, from the commit's own
# content. Findings go to stderr. Returns 1 when there are any.
swift_checks_commit() {
    local rev=$1 file output parent issues=0
    local files=()
    while IFS= read -r -d '' file; do
        case "$file" in
            *.swift) ;;
            *) continue ;;
        esac
        if git ls-tree "$rev" -- "$file" | grep -q '^120000 '; then
            continue  # a symlink
        fi
        files+=("$file")
    done < <(git diff-tree --no-commit-id --name-only -r -z --root --diff-filter=ACMR "$rev")
    if [ ${#files[@]} -eq 0 ]; then
        return 0
    fi

    swift_checks_path
    swift_checks_toolchain
    if ! swift_checks_tools; then
        echo "warning: the Swift files in this commit weren't checked: lint tools are missing." >&2
        return 1
    fi
    if parent=$(swift_checks_missing_parent); then
        echo "warning: .swiftlint.local.yml inherits from $parent, which is missing, so SwiftLint skips its rules." >&2
        issues=1
    fi
    swift_checks_lint_args

    for file in "${files[@]}"; do
        if [ -f ".swift-format" ]; then
            output=$(git cat-file blob "$rev:$file" |
                swift format lint --configuration .swift-format --assume-filename "$file" - 2>&1)
            if printf '%s' "$output" | grep -qE ': (warning|error): '; then
                printf '%s\n' "$output" >&2
                issues=1
            fi
        fi
        if ! output=$(git cat-file blob "$rev:$file" | swiftlint lint --use-stdin "${LINT_ARGS[@]}" 2>&1); then
            printf '%s\n' "${output//<nopath>/$file}" >&2
            issues=1
        fi
    done
    return $issues
}
