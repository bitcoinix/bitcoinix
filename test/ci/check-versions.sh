#!/usr/bin/env bash
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/../../helper/run-in-nix-env" "coreutils diffutils jq" "$@"

cd "${BASH_SOURCE[0]%/*}/../.."

expected=$(mktemp)
trap 'rm -f "$expected"' EXIT

nix eval --json -f helper/update-flake.nix versionsFile | jq . > "$expected"
if ! diff -u versions.json "$expected"; then
    echo "error: versions.json is out of date. Run helper/update-flake.sh and commit the generated files." >&2
    exit 1
fi
