#!/bin/sh
#
# ci_post_xcodebuild.sh - Xcode Cloud post-build hook
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

if [[ -n $CI_ARCHIVE_PATH ]]; then
    echo "note: ci_post_xcodebuild: exec"
    ./firebase_upload_symbols.sh
    ./testflight_whattotest.sh
else
    echo "warning: ci_post_xcodebuild: skipping: CI_ARCHIVE_PATH unavailable"
fi
