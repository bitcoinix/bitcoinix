#!/usr/bin/env bash
set -euo pipefail

# Keep the checkout off Python's import path when this runs on the signer's machine.
exec python3 -I "$(dirname -- "${BASH_SOURCE[0]}")/check-release-notes.py" "$@"
