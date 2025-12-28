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
    echo "note: ci_post_clone: exec swiftlint.sh"
    ./swiftlint.sh
fi
