#!/bin/bash
# Removes everything the showcase demos created.
# Run: ./showcase/cleanup_all.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for script in "$DIR"/0[1-6]_*.sh; do
    echo "🧹 $(basename "$script")"
    "$script" --cleanup
done
