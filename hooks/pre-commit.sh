#!/bin/bash
# Git and Husky entry point; no JSON input is required.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/staged-swift.sh"
staged_swift_main
