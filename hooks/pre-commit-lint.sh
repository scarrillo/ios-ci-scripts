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
command=$(echo "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Only run for git commit commands
if [[ "$command" == *"git commit"* ]] || [[ "$command" == *"git add"*"&&"*"git commit"* ]]; then
    cd "$CLAUDE_PROJECT_DIR"
    export PATH="$PATH:/opt/homebrew/bin"

    # Require both tools — block commit if missing
    MISSING_TOOLS=false
    if ! swift format --version >/dev/null 2>&1; then
        echo "ERROR: swift-format not available — requires Xcode toolchain (Swift 5.9+)" >&2
        MISSING_TOOLS=true
    fi
    if ! which swiftlint >/dev/null 2>&1; then
        echo "ERROR: swiftlint not found — install with: brew install swiftlint" >&2
        MISSING_TOOLS=true
    fi
    if $MISSING_TOOLS; then
        echo "Commit blocked: required lint tools are missing." >&2
        exit 2
    fi

    # Check if any Swift files are staged
    staged_swift_files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.swift$' || true)

    if [[ -z "$staged_swift_files" ]]; then
        echo "No Swift files staged, skipping lint." >&2
        exit 0
    fi

    # Run swift-format on staged files (auto-fix in place, then re-stage)
    if [ -f ".swift-format" ]; then
        echo "Running swift-format on staged files..." >&2
        echo "$staged_swift_files" | while IFS= read -r file; do
            if [ -f "$file" ]; then
                swift format format --configuration .swift-format --in-place "$file" 2>&1
            fi
        done
        # Re-stage any formatted files
        echo "$staged_swift_files" | while IFS= read -r file; do
            if [ -f "$file" ]; then
                git add "$file"
            fi
        done
    fi

    # Run SwiftLint on staged files only (warnings allowed, errors block)
    echo "Running SwiftLint on staged files..." >&2

    if [ -f ".swiftlint.local.yml" ]; then
        LINT_CONFIG=".swiftlint.local.yml"
    elif [ -f "ci_scripts/.swiftlint.yml" ]; then
        LINT_CONFIG="ci_scripts/.swiftlint.yml"
    else
        LINT_CONFIG=""
    fi

    # Re-read staged files (may have changed after formatting)
    staged_swift_files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.swift$' || true)

    if [[ -n "$staged_swift_files" ]]; then
        if [ -n "$LINT_CONFIG" ]; then
            LINT_OUTPUT=$(echo "$staged_swift_files" | xargs swiftlint lint --config "$LINT_CONFIG" 2>&1)
        else
            LINT_OUTPUT=$(echo "$staged_swift_files" | xargs swiftlint lint 2>&1)
        fi
        LINT_EXIT=$?

        if [[ $LINT_EXIT -eq 0 ]]; then
            echo "SwiftLint passed." >&2
            exit 0
        else
            echo "$LINT_OUTPUT" >&2
            echo "SwiftLint found errors. Please fix before committing." >&2
            exit 2  # Block the commit
        fi
    fi
fi

# Allow all other commands
exit 0
