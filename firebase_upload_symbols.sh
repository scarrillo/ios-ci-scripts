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

# CI_WORKSPACE_PATH is Xcode Cloud's own variable — generic $CI is exported by
# every CI system (GitHub Actions, etc.), where the Xcode Cloud branch's
# CI_* paths are unset and set -e fails the build.
#
# This branch is for Xcode Cloud's POST-XCODEBUILD ci_scripts context only:
# CI_ARCHIVE_PATH exists after the archive completes. Invoking this script as
# a build phase ON Xcode Cloud would land here mid-archive with an empty
# CI_ARCHIVE_PATH — run it from ci_post_xcodebuild.sh instead.
if [ -n "$CI_WORKSPACE_PATH" ]; then
	# Honor a caller-provided GOOGLE_PLIST; default preserves existing behavior.
	GOOGLE_PLIST="${GOOGLE_PLIST:-$CI_WORKSPACE_PATH/repository/$CI_PRODUCT/GoogleService-Info.plist}"

	if [ ! -f "$GOOGLE_PLIST" ]; then
		echo "note: Firebase Crashlytics: skipping - GoogleService-Info.plist not found at $GOOGLE_PLIST"
		exit 0
	fi

	echo "note: Firebase Crashlytics: upload-symbols: cloud: Product: $CI_PRODUCT"
	"$CI_DERIVED_DATA_PATH/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/upload-symbols" -gsp "$GOOGLE_PLIST" -p ios "$CI_ARCHIVE_PATH/dSYMs/"
else
	# Skip dSYM upload for Debug builds (faster iteration, no crash symbolication needed)
	if [ "$CONFIGURATION" = "Debug" ]; then
		echo "note: Firebase Crashlytics: skipping dSYM upload for Debug build"
		exit 0
	fi

	# Honor a caller-provided GOOGLE_PLIST; default preserves existing behavior.
	GOOGLE_PLIST="${GOOGLE_PLIST:-${SRCROOT}/${PRODUCT_NAME}/GoogleService-Info.plist}"

	if [ ! -f "$GOOGLE_PLIST" ]; then
		echo "note: Firebase Crashlytics: skipping - GoogleService-Info.plist not found at $GOOGLE_PLIST"
		exit 0
	fi

	export PATH="$PATH:/opt/homebrew/bin"
	echo "note: Firebase Crashlytics: run"

	LOCAL_BUILD_DIR_PATH="${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics"

	# Reference: https://github.com/firebase/firebase-ios-sdk/blob/main/Crashlytics/run
	# The /run script forwards its arguments to upload-symbols — pass the
	# resolved plist explicitly so a GOOGLE_PLIST override is actually honored
	# (the existence check above guarantees the path is valid).
	"${LOCAL_BUILD_DIR_PATH}/run" -gsp "$GOOGLE_PLIST"
fi
