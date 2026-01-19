#!/bin/bash
#
# Xcode Cloud Pre-Build Script
#
# Setup in App Store Connect:
#   Add environment variables with ENV_ prefix:
#   - ENV_AnalyticsConfig_ga4MeasurementId = G-XXXXXXXXXX
#   - ENV_AnalyticsConfig_ga4ApiSecret = (your secret, mark as "Secret")
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Generate Swift files from ENV_ variables
"$SCRIPT_DIR/generate_env_variables.sh" "${CI_PRIMARY_REPOSITORY_PATH}/Shared/EnvVariables"
