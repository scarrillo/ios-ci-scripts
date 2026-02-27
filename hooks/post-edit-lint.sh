#!/bin/bash
#
# post-edit-lint.sh - Run swift-format and SwiftLint after editing Swift files
#
# PostToolUse hook for Edit|Write. Gives Claude immediate feedback on
# style and lint issues per file, rather than discovering them at commit time.
#
# Shared via ci_scripts submodule. Project-specific exclusions belong in
# .swiftlint.local.yml (SwiftLint) or .swift-format (swift-format).
#

FILE_PATH=$(cat | jq -r '.tool_input.file_path // empty')

# Skip non-Swift files
if [[ "$FILE_PATH" != *.swift ]]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

BASENAME=$(basename "$FILE_PATH")
export PATH="$PATH:/opt/homebrew/bin"

# Check tool availability (warn but don't block edits)
HAS_SWIFT_FORMAT=true
if ! swift format --version >/dev/null 2>&1; then
  HAS_SWIFT_FORMAT=false
  echo "⚠ swift-format not available — requires Xcode toolchain (Swift 5.9+)"
fi

HAS_SWIFTLINT=true
if ! which swiftlint >/dev/null 2>&1; then
  HAS_SWIFTLINT=false
  echo "⚠ swiftlint not found — install with: brew install swiftlint"
fi

# swift-format lint (single file)
# Non-strict: warnings are informational, only errors fail.
# The pre-commit hook auto-formats before commit as a safety net.
if $HAS_SWIFT_FORMAT && [ -f ".swift-format" ]; then
  FMT_OUTPUT=$(swift format lint --configuration .swift-format "$FILE_PATH" 2>&1)
  FMT_EXIT=$?
  # Count actual issues (lines with warning/error)
  FMT_ISSUES=$(echo "$FMT_OUTPUT" | grep -cE ': (warning|error): ' || true)

  if [[ $FMT_ISSUES -eq 0 ]]; then
    echo "swift-format ($BASENAME): pass"
  else
    echo "swift-format ($BASENAME): $FMT_ISSUES issue(s)"
    echo "$FMT_OUTPUT" | grep -E ': (warning|error): ' | tail -10
  fi
fi

# SwiftLint (single file)
if $HAS_SWIFTLINT; then
  if [ -f ".swiftlint.local.yml" ]; then
    LINT_CONFIG=".swiftlint.local.yml"
  elif [ -f "ci_scripts/.swiftlint.yml" ]; then
    LINT_CONFIG="ci_scripts/.swiftlint.yml"
  else
    LINT_CONFIG=""
  fi

  if [ -n "$LINT_CONFIG" ]; then
    LINT_OUTPUT=$(swiftlint lint --config "$LINT_CONFIG" "$FILE_PATH" 2>&1)
  else
    LINT_OUTPUT=$(swiftlint lint "$FILE_PATH" 2>&1)
  fi
  LINT_EXIT=$?
  LINT_ERRORS=$(echo "$LINT_OUTPUT" | grep -c ': error:' || true)
  LINT_WARNINGS=$(echo "$LINT_OUTPUT" | grep -c ': warning:' || true)

  if [[ $LINT_ERRORS -gt 0 ]]; then
    echo "swiftlint ($BASENAME): $LINT_ERRORS error(s), $LINT_WARNINGS warning(s)"
    echo "$LINT_OUTPUT" | grep -E ': (error|warning):' | tail -15
  elif [[ $LINT_WARNINGS -gt 0 ]]; then
    echo "swiftlint ($BASENAME): $LINT_WARNINGS warning(s)"
    echo "$LINT_OUTPUT" | grep ': warning:' | tail -10
  else
    echo "swiftlint ($BASENAME): pass"
  fi
fi
