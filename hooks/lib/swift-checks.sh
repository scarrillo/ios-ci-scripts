#!/bin/bash
#
# swift-checks.sh - Shared swift-format and SwiftLint checks for the hooks
#
# Sourced by pre-commit.sh and post-commit.sh (git) and post-edit-lint.sh
# (Claude Code). Requires Bash 3.2 or newer. Messages go to stderr.
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

# Print the Swift files to check as "<blob id><TAB><path>", each ending in
# NUL: files added or modified in the staged content (no argument), or in
# commit $1 compared with its first parent. Skips symlinks, and for a merge,
# files whose content matches another parent (brought in unchanged by the
# merge; a heuristic, not a detector for hand-resolved conflicts).
swift_checks_files() {
    local rev=$1 meta file mode blob parent inherited merge_head base
    local diff_args=() others=()
    if [ -z "$rev" ]; then
        diff_args=(--cached)
        merge_head=$(git rev-parse --git-path MERGE_HEAD 2>/dev/null)
        if [ -n "$merge_head" ] && [ -f "$merge_head" ]; then
            while IFS= read -r parent; do
                others+=("$parent")
            done < "$merge_head"
        fi
    else
        base=$(git rev-parse -q --verify "$rev^1") || base=$(git hash-object -t tree /dev/null)
        diff_args=("$base" "$rev")
        while IFS= read -r parent; do
            others+=("$parent")
        done < <(git rev-parse "$rev^@" | tail -n +2)
    fi
    git diff "${diff_args[@]}" --raw --no-abbrev -z --no-renames --no-ext-diff --diff-filter=ACM |
        while IFS= read -r -d '' meta && IFS= read -r -d '' file; do
            case "$file" in
                *.swift) ;;
                *) continue ;;
            esac
            # meta is ":<old mode> <new mode> <old blob> <new blob> <status>"
            read -r _ mode _ blob _ <<< "$meta"
            if [ "$mode" = 120000 ]; then
                echo "warning: $file is a symlink, so it was not formatted or linted." >&2
                continue
            fi
            inherited=false
            for parent in "${others[@]}"; do
                if [ "$(git rev-parse -q --verify "$parent:$file" 2>/dev/null)" = "$blob" ]; then
                    inherited=true
                    break
                fi
            done
            if $inherited; then
                continue
            fi
            printf '%s\t%s\0' "$blob" "$file"
        done
}

# Split the files from swift_checks_files into SWIFT_FULL, whose working
# copy is the content being checked, and SWIFT_PARTIAL, whose working copy
# differs (unstaged changes, or now a symlink) and is checked from that
# content instead. Both hold "<blob id><TAB><path>" entries.
swift_checks_classify() {
    local entry blob file
    SWIFT_FULL=()
    SWIFT_PARTIAL=()
    while IFS= read -r -d '' entry; do
        blob=${entry%%$'\t'*}
        file=${entry#*$'\t'}
        if [ ! -L "$file" ] && [ -f "$file" ] && [ "$(git hash-object -- "$file" 2>/dev/null)" = "$blob" ]; then
            SWIFT_FULL+=("$entry")
        else
            SWIFT_PARTIAL+=("$entry")
        fi
    done < <(swift_checks_files "$1")
}

# Run SwiftLint on SWIFT_FULL by path and on SWIFT_PARTIAL from their
# content, naming those "<path> ($1)". Prints the findings and returns 1 when
# SwiftLint reports errors or fails.
swift_checks_lint() {
    local entry output failed=false findings=""
    local paths=()
    swift_checks_lint_args
    for entry in "${SWIFT_FULL[@]}"; do
        paths+=("${entry#*$'\t'}")
    done
    if [ ${#paths[@]} -gt 0 ]; then
        output=$(swiftlint lint "${LINT_ARGS[@]}" -- "${paths[@]}" 2>&1) || failed=true
        findings+="$output"$'\n'
    fi
    # Standard input doesn't apply the config's `excluded` paths
    for entry in "${SWIFT_PARTIAL[@]}"; do
        output=$(git cat-file blob "${entry%%$'\t'*}" | swiftlint lint --use-stdin "${LINT_ARGS[@]}" 2>&1) || failed=true
        findings+="${output//<nopath>/${entry#*$'\t'} ($1)}"$'\n'
    done
    if $failed; then
        printf '%s' "$findings" >&2
        return 1
    fi
    return 0
}

# Format and lint the staged Swift files of the repository in the current
# directory. Returns 1 when the commit should be blocked.
swift_checks_staged() {
    local entry file output parent

    swift_checks_path
    swift_checks_toolchain
    if ! swift_checks_tools; then
        echo "Commit blocked: required lint tools are missing." >&2
        return 1
    fi

    swift_checks_classify ""
    if [ $((${#SWIFT_FULL[@]} + ${#SWIFT_PARTIAL[@]})) -eq 0 ]; then
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
        for entry in "${SWIFT_PARTIAL[@]}"; do
            echo "warning: ${entry#*$'\t'} has unstaged changes, so it was not auto-formatted." >&2
        done
        for entry in "${SWIFT_FULL[@]}"; do
            file=${entry#*$'\t'}
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

    # Run SwiftLint on staged files only (warnings allowed, errors block).
    # Formatting changed only fully staged files, which are linted by path.
    echo "Running SwiftLint on staged files..." >&2
    if ! swift_checks_lint staged; then
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

# Check the Swift files commit $1 added or changed, the same files
# swift_checks_staged checks, without changing anything. Findings go to
# stderr. Returns 1 when there are any.
swift_checks_commit() {
    local entry file output parent issues=0

    swift_checks_classify "$1"
    if [ $((${#SWIFT_FULL[@]} + ${#SWIFT_PARTIAL[@]})) -eq 0 ]; then
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

    if [ -f ".swift-format" ]; then
        for entry in "${SWIFT_FULL[@]}" "${SWIFT_PARTIAL[@]}"; do
            file=${entry#*$'\t'}
            if ! output=$(git cat-file blob "${entry%%$'\t'*}" |
                swift format lint --configuration .swift-format --assume-filename "$file" - 2>&1); then
                printf '%s\n' "$output" >&2
                echo "warning: swift-format couldn't check $file." >&2
                issues=1
            elif printf '%s' "$output" | grep -qE ': (warning|error): '; then
                printf '%s\n' "$output" >&2
                issues=1
            fi
        done
    fi
    swift_checks_lint committed || issues=1
    return $issues
}
