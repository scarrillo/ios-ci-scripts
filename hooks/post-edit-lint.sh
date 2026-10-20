#!/bin/bash
#
# post-edit-lint.sh - Run swift-format and SwiftLint after editing Swift files
#
# PostToolUse hook for Edit|Write. Gives Claude immediate feedback on
# style and lint issues per file, rather than discovering them at commit time.
# Claude only sees a PostToolUse hook's output as JSON (additionalContext), so
# issues are sent that way; a clean file prints plain "pass" lines.
#
# Shared via ci_scripts submodule. Project-specific exclusions belong in
# .swiftlint.local.yml (SwiftLint) or .swift-format (swift-format).
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

input=$(cat)
if ! command -v jq >/dev/null 2>&1; then
    case "$input" in
        *'.swift"'*)
            echo '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"post-edit-lint: jq is missing, so edited Swift files are not linted. Install with: brew install jq"}}' ;;
    esac
    exit 0
fi
FILE_PATH=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')

# Skip non-Swift files
if [[ "$FILE_PATH" != *.swift ]]; then
  exit 0
fi

# Use the configs of the edited file's repository (a worktree or submodule has its own)
FILE_REPO=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null)
cd "${FILE_REPO:-${CLAUDE_PROJECT_DIR:-.}}" || exit 0

BASENAME=$(basename "$FILE_PATH")
swift_checks_toolchain

# Findings for Claude; "pass" lines only go to the transcript
REPORT=""
PASSES=""
report() { REPORT+="$1"$'\n'; }

# Check tool availability (warn but don't block edits)
HAS_SWIFT_FORMAT=true
if ! swift format --version >/dev/null 2>&1; then
  HAS_SWIFT_FORMAT=false
  report "⚠ swift-format not available — requires Xcode toolchain (Swift 5.9+)"
fi

HAS_SWIFTLINT=true
if ! which swiftlint >/dev/null 2>&1; then
  HAS_SWIFTLINT=false
  report "⚠ swiftlint not found — install with: brew install swiftlint"
elif ! swiftlint version >/dev/null 2>&1; then
  # Otherwise its output has no errors and the file would report a pass.
  HAS_SWIFTLINT=false
  report "⚠ $(which swiftlint) can't run (built for another CPU architecture?)"
fi

if PARENT=$(swift_checks_missing_parent); then
  report "⚠ .swiftlint.local.yml inherits from $PARENT, which is missing, so SwiftLint skips its rules. If it comes from a submodule, run: git submodule update --init"
fi

# swift-format lint (single file)
# Non-strict: warnings are informational, only errors fail.
# The pre-commit hook auto-formats before commit as a safety net.
if $HAS_SWIFT_FORMAT && [ -f ".swift-format" ]; then
  FMT_OUTPUT=$(swift format lint --configuration .swift-format -- "$FILE_PATH" 2>&1)
  # Count actual issues (lines with warning/error)
  FMT_ISSUES=$(echo "$FMT_OUTPUT" | grep -cE ': (warning|error): ' || true)

  if [[ $FMT_ISSUES -eq 0 ]]; then
    PASSES+="swift-format ($BASENAME): pass"$'\n'
  else
    report "swift-format ($BASENAME): $FMT_ISSUES issue(s)"
    report "$(echo "$FMT_OUTPUT" | grep -E ': (warning|error): ' | tail -10)"
  fi
fi

# SwiftLint (single file)
if $HAS_SWIFTLINT; then
  swift_checks_lint_args
  LINT_OUTPUT=$(swiftlint lint "${LINT_ARGS[@]}" -- "$FILE_PATH" 2>&1)
  LINT_ERRORS=$(echo "$LINT_OUTPUT" | grep -c ': error:' || true)
  LINT_WARNINGS=$(echo "$LINT_OUTPUT" | grep -c ': warning:' || true)

  if [[ $LINT_ERRORS -gt 0 ]]; then
    report "swiftlint ($BASENAME): $LINT_ERRORS error(s), $LINT_WARNINGS warning(s)"
    report "$(echo "$LINT_OUTPUT" | grep -E ': (error|warning):' | tail -15)"
  elif [[ $LINT_WARNINGS -gt 0 ]]; then
    report "swiftlint ($BASENAME): $LINT_WARNINGS warning(s)"
    report "$(echo "$LINT_OUTPUT" | grep ': warning:' | tail -10)"
  else
    PASSES+="swiftlint ($BASENAME): pass"$'\n'
  fi
fi

if [ -n "$REPORT" ]; then
  jq -n --arg context "post-edit-lint: $REPORT$PASSES" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $context}}'
else
  printf '%s' "$PASSES"
fi
