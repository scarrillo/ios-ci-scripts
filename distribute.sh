#!/bin/bash
#
# distribute.sh - Build an ad-hoc IPA and upload it to Firebase App Distribution
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2024-2026 Shawn Carrillo
#
# Usage: ./ci_scripts/distribute.sh [--skip-upload] [--notes "release notes"]
#
# Configuration (project root .env, or exported in the environment):
#   FIREBASE_APP_ID         Required for upload. Firebase console -> Project
#                           settings -> your iOS app -> App ID
#                           (looks like 1:1234567890:ios:abc123def456)
#   FIREBASE_TESTER_GROUPS  Optional. Comma-separated tester group aliases.
#   SCHEME                  Optional. Defaults to the .xcodeproj basename.
#
# Firebase App Distribution is delivery only — it does not require the
# Firebase SDK in the app. Registering the iOS app in a Firebase project is
# enough to obtain the App ID; no GoogleService-Info.plist needs shipping.
#
# Phases:
#   Phase 1 (current) — local. Runs on a developer machine: auth is the
#   firebase CLI's cached login, signing is local Xcode with
#   -allowProvisioningUpdates. This is the supported path today.
#   Phase 2 (later) — CI. Auth via ambient credentials
#   (GOOGLE_APPLICATION_CREDENTIALS service account, or workload identity);
#   signing material provisioned into the runner. Not built yet — but the
#   auth preflight below already accepts ambient credentials, so a CI
#   environment is not blocked by an interactive-login check.
#
# Signing: the archive/export runs with -allowProvisioningUpdates, so Xcode
# manages the distribution certificate and the ad-hoc profile. New tester
# devices must be registered in the Apple Developer portal (Firebase collects
# UDIDs from testers); the next export picks them up automatically.
#
# Bash Reference: https://tldp.org/LDP/abs/html/comparison-ops.html
# Shell options:
#   set -e : Exit immediately if a command exits with a non-zero status
# Test operators:
#   -n STRING : True if string is not empty
#   -z STRING : True if string is empty
#   -f PATH   : True if path exists and is a regular file
#

set -e

# Parse arguments
SKIP_UPLOAD=false
RELEASE_NOTES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-upload)
            SKIP_UPLOAD=true
            ;;
        --notes)
            # Without this guard, `--notes` as the final argument leaves the
            # loop's own shift with nothing to consume, and set -e kills the
            # script with no message at all.
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "Error: --notes requires a value"
                echo "Usage: ./ci_scripts/distribute.sh [--skip-upload] [--notes \"release notes\"]"
                exit 1
            fi
            shift
            RELEASE_NOTES="$1"
            ;;
        *)
            echo "Error: Unknown argument '$1'"
            echo "Usage: ./ci_scripts/distribute.sh [--skip-upload] [--notes \"release notes\"]"
            exit 1
            ;;
    esac
    shift
done

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Project-local configuration. Follows the .env.example convention: values
# are `export`ed, the file lives at the project root and is gitignored.
if [ -f "$PROJECT_ROOT/.env" ]; then
    # shellcheck disable=SC1091
    . "$PROJECT_ROOT/.env"
fi

# Find .xcodeproj directory dynamically (same discovery as bump-version.sh)
XCODEPROJ=$(find "$PROJECT_ROOT" -maxdepth 1 -name "*.xcodeproj" -type d | head -1)

if [ -z "$XCODEPROJ" ]; then
    echo "Error: No .xcodeproj found in $PROJECT_ROOT"
    exit 1
fi

SCHEME="${SCHEME:-$(basename "$XCODEPROJ" .xcodeproj)}"
BUILD_DIR="$PROJECT_ROOT/build/distribute"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

echo "Using project: $(basename "$XCODEPROJ")"
echo "Scheme: $SCHEME"

# Preflight the upload requirements before spending minutes on a build.
if [ "$SKIP_UPLOAD" != true ]; then
    if [ -z "$FIREBASE_APP_ID" ]; then
        echo "Error: FIREBASE_APP_ID is not set."
        echo "  Add it to $PROJECT_ROOT/.env (see ci_scripts/.env.example),"
        echo "  or run with --skip-upload to build without distributing."
        exit 1
    fi

    if ! command -v firebase >/dev/null 2>&1; then
        echo "Error: firebase CLI not found. Install: npm i -g firebase-tools"
        exit 1
    fi

    # Expired auth fails late and cryptically inside the upload; check first.
    # Ambient credentials (Phase 2, CI) never appear in login:list — a set
    # GOOGLE_APPLICATION_CREDENTIALS or FIREBASE_TOKEN is its own evidence,
    # so only the interactive path is gated on a cached login.
    if [ -z "$GOOGLE_APPLICATION_CREDENTIALS" ] && [ -z "$FIREBASE_TOKEN" ]; then
        if ! firebase login:list 2>/dev/null | grep -q "Logged in"; then
            echo "Error: firebase CLI is not authenticated. Run: firebase login"
            exit 1
        fi
    fi
fi

# Archive
echo ""
echo "Archiving (Release)..."
xcodebuild archive \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -quiet

# Export options are generated rather than committed per-project: the only
# project-specific value is the team, and the archive already knows it.
TEAM_ID=$(xcodebuild -project "$XCODEPROJ" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | grep -m1 "DEVELOPMENT_TEAM" | sed 's/.*= //')

if [ -z "$TEAM_ID" ]; then
    echo "Error: Could not determine DEVELOPMENT_TEAM from build settings"
    exit 1
fi

# "release-testing" is Xcode 15.3+'s name for what was previously "ad-hoc".
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>release-testing</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
</dict>
</plist>
PLIST

echo "Exporting ad-hoc IPA..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    -quiet

IPA=$(find "$EXPORT_DIR" -maxdepth 1 -name "*.ipa" | head -1)

if [ -z "$IPA" ]; then
    echo "Error: Export produced no .ipa in $EXPORT_DIR"
    exit 1
fi

echo "Exported: $IPA"

if [ "$SKIP_UPLOAD" = true ]; then
    echo ""
    echo "Done (upload skipped)."
    exit 0
fi

# Default release notes: everything since the last release tag, falling back
# to the latest commit subject for repos without rel.v* tags yet.
if [ -z "$RELEASE_NOTES" ]; then
    LAST_TAG=$(git -C "$PROJECT_ROOT" describe --tags --abbrev=0 --match "rel.v*" 2>/dev/null || true)
    if [ -n "$LAST_TAG" ]; then
        RELEASE_NOTES=$(git -C "$PROJECT_ROOT" log --format="- %s" "$LAST_TAG"..HEAD)
        # The tag may already point at HEAD (tag-on-merge keeps it current),
        # leaving an empty range; describe the tagged state instead.
        if [ -z "$RELEASE_NOTES" ]; then
            RELEASE_NOTES="Build at $LAST_TAG ($(git -C "$PROJECT_ROOT" log -1 --format=%s))"
        fi
    else
        RELEASE_NOTES=$(git -C "$PROJECT_ROOT" log -1 --format="- %s")
    fi
fi

echo ""
echo "Uploading to Firebase App Distribution..."
firebase appdistribution:distribute "$IPA" \
    --app "$FIREBASE_APP_ID" \
    ${FIREBASE_TESTER_GROUPS:+--groups "$FIREBASE_TESTER_GROUPS"} \
    --release-notes "$RELEASE_NOTES"

echo ""
echo "Done."
