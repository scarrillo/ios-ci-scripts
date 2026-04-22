#!/bin/bash
#
# Xcode Cloud Pre-Build Script
#
# Setup in App Store Connect:
#   Add environment variables with an ENV_<Namespace>_ prefix. The <Namespace>
#   segment is human-organizational (generate_xcconfig.sh strips any
#   ENV_<anything>_ prefix before writing the xcconfig key). Convention is to
#   match your product/scheme name so 1Password and Xcode Cloud stay aligned.
#
#   Example (replace <ProductName> with your project's scheme name):
#     - ENV_<ProductName>_ga4ApiSecret = (your secret, mark as "Secret")
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Generate xcconfig files from ENV_ variables
"$SCRIPT_DIR/generate_xcconfig.sh" "${CI_PRIMARY_REPOSITORY_PATH}/Config"
