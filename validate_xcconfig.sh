#!/bin/bash
#
# Validate that required build settings are resolved from xcconfig.
#
# Run Script build phases pass xcconfig-defined build settings as environment
# variables. This script checks that each required variable is set and not
# an unresolved plist placeholder.
#
# Usage:
#   validate_xcconfig.sh <key1> [key2] ...
#
# Example (in Xcode Run Script):
#   ./ci_scripts/validate_xcconfig.sh ga4MeasurementId ga4ApiSecret
#

set -e

if [ $# -eq 0 ]; then
    echo "error: validate_xcconfig.sh requires at least one key name."
    exit 1
fi

# Check that the xcconfig file exists
XCCONFIG="${SRCROOT}/Config/${PROJECT_NAME}Config.xcconfig"
if [ ! -f "$XCCONFIG" ]; then
    echo "error: ${PROJECT_NAME}Config.xcconfig not found at $XCCONFIG. Run generate_xcconfig.sh (see ci_scripts/.env.example)."
    exit 1
fi

# Check that each required key resolved to a value
failed=0
for key in "$@"; do
    value=$(eval printf '%s' "\$$key")
    if [ -z "$value" ] || case "$value" in '$('*) true;; *) false;; esac; then
        echo "error: '$key' not found in ${PROJECT_NAME}Config.xcconfig. Ensure the ENV_ variable is set and run generate_xcconfig.sh."
        failed=1
    fi
done

if [ "$failed" -eq 1 ]; then
    exit 1
fi
