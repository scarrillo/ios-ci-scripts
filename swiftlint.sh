#!/bin/sh
#
# swiftlint.sh - Install and run SwiftLint for code linting
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2024-2025 Shawn Carrillo
#
# Usage: ./swiftlint.sh [--strict]
#   --strict : Treat warnings as errors (fails on any violation)
#
# Bash Reference: https://tldp.org/LDP/abs/html/comparison-ops.html
# Shell options:
#   set -e : Exit immediately if a command exits with a non-zero status
# Test operators:
#   -n STRING : True if string is not empty
#   -z STRING : True if string is empty
#   -d PATH   : True if path exists and is a directory
#

set -e

# Parse arguments
STRICT_MODE=""
for arg in "$@"; do
    case $arg in
        --strict)
            STRICT_MODE="--strict"
            echo "note: SwiftLint Script: Strict mode enabled"
            shift
            ;;
    esac
done

if [ -n "$CI" ]; then
    echo "note: SwiftLint Script: Installing SwiftLint in CI: [$CI]"
    SWIFT_LINT_TARGET="${CI_WORKSPACE_PATH}/repository/"

    brew install swiftlint
else
	export PATH="$PATH:/opt/homebrew/bin"
    echo "note: SwiftLint Script: local"
    # SRCROOT is set by Xcode, fall back to PWD for command line usage
    SWIFT_LINT_TARGET="${SRCROOT:-$PWD}"
fi

if which swiftlint >/dev/null; then
    # Use local config if it exists (inherits from ci_scripts), otherwise use base config
    echo "note: SwiftLint Script: Looking for: ${SWIFT_LINT_TARGET}/.swiftlint.local.yml"
    ls -la "${SWIFT_LINT_TARGET}"/.swiftlint* 2>/dev/null || echo "note: No .swiftlint* files found"
    if [ -f "${SWIFT_LINT_TARGET}/.swiftlint.local.yml" ]; then
        SWIFT_LINT_FILE="${SWIFT_LINT_TARGET}/.swiftlint.local.yml"
    else
        SWIFT_LINT_FILE="${SWIFT_LINT_TARGET}/ci_scripts/.swiftlint.yml"
    fi

    echo "note: SwiftLint Script: Config: ${SWIFT_LINT_FILE}"
    swiftlint $STRICT_MODE --config "${SWIFT_LINT_FILE}" $SWIFT_LINT_TARGET
else
    echo "warning: SwiftLint not installed"
fi
