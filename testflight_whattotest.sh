#!/bin/sh
#
# testflight_whattotest.sh - Generate TestFlight release notes from git history
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

echo "note: WhatToTest: exec"
# TestFlight tester notes - WhatToTest
#if [[ -d "$CI_APP_STORE_SIGNED_APP_PATH" ]]; then

TESTFLIGHT_DIR_PATH="./TestFlight"
if [ ! -d "$TESTFLIGHT_DIR_PATH" ]; then
    mkdir $TESTFLIGHT_DIR_PATH
fi

# git fetch --deepen 3 &&
git log -20 --pretty=format:"- %cs: %s" > $TESTFLIGHT_DIR_PATH/WhatToTest.en-US.txt
#fi
