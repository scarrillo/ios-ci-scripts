#!/usr/bin/env bash
# Bump XcodeGen versions using trusted helpers and pinned PyYAML.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I -B "$script_dir/scripts/distribution/release_version.py" "$@"
