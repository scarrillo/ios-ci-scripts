#!/bin/sh
#
# firebase_upload_symbols.sh - Upload dSYM files to Firebase Crashlytics
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
#   -f PATH   : True if path exists and is a regular file
#

set -e

if [ -n "$CI" ]; then
	GOOGLE_PLIST="$CI_WORKSPACE_PATH/repository/$CI_PRODUCT/GoogleService-Info.plist"

	if [ ! -f "$GOOGLE_PLIST" ]; then
		echo "note: Firebase Crashlytics: skipping - GoogleService-Info.plist not found"
		exit 0
	fi

	echo "note: Firebase Crashlytics: upload-symbols: cloud: Product: $CI_PRODUCT"
	$CI_DERIVED_DATA_PATH/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols -gsp "$GOOGLE_PLIST" -p ios $CI_ARCHIVE_PATH/dSYMs/
else
	GOOGLE_PLIST="${SRCROOT}/${PRODUCT_NAME}/GoogleService-Info.plist"

	if [ ! -f "$GOOGLE_PLIST" ]; then
		echo "note: Firebase Crashlytics: skipping - GoogleService-Info.plist not found"
		exit 0
	fi

	export PATH="$PATH:/opt/homebrew/bin"
	echo "note: Firebase Crashlytics: run"

	LOCAL_BUILD_DIR_PATH="${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics"

	# Reference: https://github.com/firebase/firebase-ios-sdk/blob/main/Crashlytics/run
	# The /run script calls upload-symbols internally, so we don't need to invoke it separately.
	"${LOCAL_BUILD_DIR_PATH}/run"
fi
