#!/usr/bin/env bash

# Build the deployment examples in ../../examples with their deployment tools.
# The examples pin a bitcoinix release; this script builds them against this
# checkout instead.
#
# This script can also be run locally for testing:
#   ./deployment-examples.sh [flakes|colmena]...
#
# This script leaves no persistent traces on the host system (outside of /nix/store).

set -euo pipefail

repo=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
tmpDir=$(mktemp -d)
trap 'rm -rf "$tmpDir"' EXIT

# The examples set the configVersion of the release they pin. Build them with the
# latest configVersion of this checkout, which may have newer versioning entries.
configVersion=$(sed -n 's/^ *version = "\([0-9.]*\)";$/\1/p' "$repo/modules/versioning.nix" | sort -V | tail -1)

# Copy an example, so that locking doesn't write to the checkout, set its
# configVersion and lock its bitcoinix input to this checkout
prepareExample() {
    cp -r "$repo/examples/$1" "$tmpDir/$1"
    sed -i.orig "s/configVersion = \"[0-9.]*\";/configVersion = \"$configVersion\";/" "$tmpDir/$1/flake.nix"
    grep -q "configVersion = \"$configVersion\";" "$tmpDir/$1/flake.nix"
    nix flake lock "$tmpDir/$1" --override-input bitcoinix "$repo"
    cd "$tmpDir/$1"
}

# Deployment with `nixos-rebuild --flake`
buildFlakes() {
    prepareExample flakes
    nix run --inputs-from "$repo" nixpkgs#nixos-rebuild -- build --flake .#fullnode
}

buildColmena() {
    prepareExample colmena
    # The node builds on the target host; build here instead
    nix develop --command colmena build --on fullnode --no-build-on-target
}

if [[ $# == 0 ]]; then
    set -- flakes colmena
fi
for example in "$@"; do
    echo "Building deployment example '$example'"
    case $example in
        flakes) (buildFlakes) ;;
        colmena) (buildColmena) ;;
        *) >&2 echo "Unknown deployment example '$example'"; exit 1 ;;
    esac
done
