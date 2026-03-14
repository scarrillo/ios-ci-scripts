#!/bin/bash
#
# Generate xcconfig file from environment variables
#
# Converts ENV_<ProductName>_<PropertyName>=value environment variables into
# an xcconfig file for Xcode. Run once during project setup (or when secrets
# change) — the generated file persists across builds.
#
# The product_name argument maps to the <ProductName> prefix in env vars:
#   ENV_MyApp_apiKey=your-key  →  apiKey = your-key
#
# Sources (checked in order):
#   1. ENV_ variables in the current shell environment
#   2. Fallback: Existing xcconfig left as-is
#
# Usage:
#   generate_xcconfig.sh <output_directory> [product_name]
#
#   output_directory: Where to write the xcconfig file
#   product_name:     Product name — used for file naming and ENV_ prefix
#                     (default: CI_PRODUCT or "App")
#                     Output: <output_dir>/<product_name>Config.xcconfig
#
# --- Local Setup (1Password Environments) ---
#
#   1. Install 1Password CLI: https://developer.1password.com/docs/cli/get-started/
#   2. Create an Environment in 1Password (Developer → View Environments)
#   3. Add variables with ENV_<ProductName>_ prefix (e.g., ENV_MyApp_apiKey)
#   4. Copy ci_scripts/.env.example to your project root as .env
#   5. Run once (subshell keeps tokens out of your session):
#        (source .env && op run --environment "$OP_ENVIRONMENT_ID" -- \
#          ./ci_scripts/generate_xcconfig.sh <output_dir> <product_name>)
#
# --- CI Setup (Xcode Cloud) ---
#
#   1. Go to App Store Connect → Xcode Cloud → Environment Variables
#   2. Add variables with ENV_<ProductName>_ prefix:
#        ENV_MyApp_apiKey=your-api-key
#        ENV_MyApp_measurementId=G-XXXXXXXXXX
#   3. ci_pre_xcodebuild.sh calls this script automatically
#

set -e

OUTPUT_DIR="${1:-$CI_PRIMARY_REPOSITORY_PATH}"
PRODUCT_NAME="${2:-${CI_PRODUCT:-App}}"

if [ -z "$OUTPUT_DIR" ]; then
    echo "Error: Output directory not specified"
    echo "Usage: generate_xcconfig.sh <output_directory> [product_name]"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

output_file="$OUTPUT_DIR/${PRODUCT_NAME}Config.xcconfig"

# --- Source 1: Environment variables ---
env_vars=$(env | grep '^ENV_' || true)

if [ -n "$env_vars" ]; then
    echo "Generating $output_file from ENV_ variables..."

    cat > "$output_file" << EOF
//
//  ${PRODUCT_NAME}Config.xcconfig
//
//  Auto-generated from environment — DO NOT EDIT
//
//  Access in Info.plist: \$(PROPERTY_NAME)
//  Access in Swift: Bundle.main.infoDictionary?["PropertyName"]
//

EOF

    env | grep '^ENV_' | sort | while IFS='=' read -r var value; do
        property_name=$(echo "$var" | sed 's/^ENV_[^_]*_//')
        echo "$property_name = $value" >> "$output_file"
    done

    echo "Generated $output_file from environment"
    exit 0
fi

# --- Source 2: Fallback ---
if [ -f "$output_file" ]; then
    echo "Using existing $output_file (no ENV_ variables found)"
    exit 0
fi

# No source available
echo "Warning: No config source available"
echo "  - No ENV_ variables found"
echo "  - No existing $output_file"
echo ""
echo "Local setup (1Password Environments):"
echo "  1. Create an Environment in 1Password (Developer → View Environments)"
echo "  2. Add variables with ENV_${PRODUCT_NAME}_ prefix (e.g., ENV_${PRODUCT_NAME}_myKey)"
echo "  3. Copy ci_scripts/.env.example to project root as .env and fill in values"
echo "  4. Run: source .env && op run --environment \"\$OP_ENVIRONMENT_ID\" -- \\"
echo "       ./ci_scripts/generate_xcconfig.sh $(basename "$OUTPUT_DIR") ${PRODUCT_NAME}"
echo ""
echo "CI setup (Xcode Cloud):"
echo "  1. Add ENV_${PRODUCT_NAME}_ prefixed variables in App Store Connect → Environment Variables"
echo "  2. ci_pre_xcodebuild.sh calls this script automatically"
exit 1
