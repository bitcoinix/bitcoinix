#!/usr/bin/env bash
set -euo pipefail

cd "${BASH_SOURCE[0]%/*}"

nbFlake=$(realpath ../..)

# Fetch the `flake-info` build from cachix. The CI workflow pushes it.
nix run .#cachix -- use bitcoinix
# Upstream caches its patched Nix dependency, avoiding a Nix rebuild on cache misses.
nix run .#cachix -- use nixos-search

# shellcheck disable=SC2016
PATH=$(nix shell -L .#{flake-info,jq} -c sh -c 'echo $PATH')

# flake-info uses `nixpkgs` from NIX_PATH
NIX_PATH="nixpkgs=$(nix flake metadata --json --inputs-from "$nbFlake" nixpkgs | jq -r .path)"
export NIX_PATH

echo "Running flake-info (nixos-search)"
flake-info --json flake "$nbFlake" >/dev/null
