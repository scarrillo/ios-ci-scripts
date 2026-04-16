#!/bin/sh
#
# ci_post_clone.sh - Xcode Cloud post-clone hook
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
    # Install Metal Toolchain if project contains Metal shaders (required by Xcode 26+)
    # Some Xcode Cloud images ship with the toolchain pre-installed; the download
    # then fails with "already imported". Treat that as success and surface
    # any other error.
    PROJECT_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"
    if find "$PROJECT_ROOT" -maxdepth 5 -name "*.metal" | grep -q .; then
        echo "note: ci_post_clone: ensuring Metal Toolchain is installed"
        if ! metal_output=$(xcodebuild -downloadComponent MetalToolchain 2>&1); then
            if echo "$metal_output" | grep -q "already imported"; then
                echo "note: ci_post_clone: Metal Toolchain already present, skipping"
            else
                echo "$metal_output" >&2
                exit 1
            fi
        fi
    fi

    echo "note: ci_post_clone: exec swiftlint.sh"
    ./swiftlint.sh
fi
