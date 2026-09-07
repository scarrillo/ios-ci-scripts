#!/bin/bash
# Shared staged-file checks. Requires Bash 3.2 or newer.
staged_swift_main() (
    set -euo pipefail
    cd "$(git rev-parse --show-toplevel)"
    export PATH="$PATH:/opt/homebrew/bin"
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/staged-swift.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    git diff --cached --name-only -z --diff-filter=ACMR > "$scratch/selected"
    files=()
    merge_head=$(git rev-parse --git-path MERGE_HEAD)
    while IFS= read -r -d '' file; do
        [[ "$file" == *.swift ]] || continue
        # Skip content inherited unchanged from any merge parent. This is a
        # heuristic, not a detector for manually resolved conflicts.
        inherited=false
        if [[ -f "$merge_head" ]]; then
            while IFS= read -r parent; do
                if git diff --cached --quiet "$parent" -- ":(literal)$file"; then
                    inherited=true
                    break
                else
                    status=$?
                    [[ "$status" == 1 ]] || exit "$status"
                fi
            done < "$merge_head"
        fi
        "$inherited" || files+=("$file")
    done < "$scratch/selected"
    [[ ${#files[@]} -gt 0 ]] || exit 0

    # Finish preflight before formatting, staging, or optional network use.
    for file in "${files[@]}"; do
        if [[ -L "$file" || ! -f "$file" ]]; then
            printf 'Cannot check non-regular Swift file: %q\n' "$file" >&2
            exit 1
        fi
        if ! git diff --quiet -- ":(literal)$file"; then
            printf 'Commit blocked: %q has unstaged changes. Finish staging it or separate the changes before retrying.\n' "$file" >&2
            exit 1
        fi
    done

    config=()
    if [[ -f .swiftlint.local.yml ]]; then
        config=(--config .swiftlint.local.yml)
        # SwiftLint parses arbitrary YAML; detect the conventional shared parent
        # here so a missing submodule never silently disables inherited rules.
        if [[ ! -f ci_scripts/.swiftlint.yml ]] &&
            grep -Eq '^[[:space:]]*parent_config:.*ci_scripts/\.swiftlint\.yml' .swiftlint.local.yml; then
            if [[ "${CI_SCRIPTS_INIT_SUBMODULE:-0}" == 1 ]]; then
                git submodule update --init --recursive -- ci_scripts
            fi
            if [[ ! -f ci_scripts/.swiftlint.yml ]]; then
                echo 'Missing ci_scripts/.swiftlint.yml parent config. Initialize the submodule, or explicitly set CI_SCRIPTS_INIT_SUBMODULE=1.' >&2
                exit 1
            fi
        fi
    elif [[ -f ci_scripts/.swiftlint.yml ]]; then
        config=(--config ci_scripts/.swiftlint.yml)
    fi

    if [[ -z "${DEVELOPER_DIR:-}" ]] && command -v xcode-select >/dev/null 2>&1; then
        developer=$(xcode-select -p 2>/dev/null || true)
        if [[ "$developer" == */CommandLineTools && -d /Applications/Xcode.app/Contents/Developer ]]; then
            export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        fi
    fi
    swift format --version >/dev/null 2>&1 || {
        echo 'Commit blocked: swift-format is unavailable in the selected Swift toolchain.' >&2
        exit 1
    }
    command -v swiftlint >/dev/null 2>&1 || {
        echo 'Commit blocked: swiftlint is missing. Install it before retrying.' >&2
        exit 1
    }
    if [[ -f .swift-format ]]; then
        for file in "${files[@]}"; do
            swift format format --configuration .swift-format --in-place -- "$file"
        done
        for file in "${files[@]}"; do
            git add -- ":(literal)$file"
        done
    fi
    # Empty-array expansion trips nounset on Bash 3.2.
    if [[ ${#config[@]} -gt 0 ]]; then
        swiftlint lint "${config[@]}" -- "${files[@]}"
    else
        swiftlint lint -- "${files[@]}"
    fi
)
