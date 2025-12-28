#!/bin/sh
#
# swiftlint.sh - Install and run SwiftLint for code linting
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2024-2025 Shawn Carrillo
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

if [ -n "$CI" ]; then
    echo "note: SwiftLint Script: Installing SwiftLint in CI: [$CI]"
    SWIFT_LINT_TARGET="${CI_WORKSPACE_PATH}/repository/"

    brew install swiftlint
else
	export PATH="$PATH:/opt/homebrew/bin"
    echo "note: SwiftLint Script: local"
    SWIFT_LINT_TARGET="${SRCROOT}"
    #SWIFT_LINT_FILE="${SWIFT_LINT_TARGET}/ci_scripts/.swiftlint.yml" # $SRCROOT / $PWD work locally
fi

if which swiftlint >/dev/null; then
    SWIFT_LINT_FILE="${SWIFT_LINT_TARGET}/ci_scripts/.swiftlint.yml"

    echo "note: SwiftLint Script: Config: ${SWIFT_LINT_FILE}"
    swiftlint --config "${SWIFT_LINT_FILE}" $SWIFT_LINT_TARGET
    #THIS Works - Explicit path, just in case for xcode cloud
    #swiftlint --config ./.swiftlint.yml
    #strict mode will block build in xcode cloud
    #swiftlint --strict $CI_WORKSPACE
else
    echo "warning: SwiftLint not installed"
fi
