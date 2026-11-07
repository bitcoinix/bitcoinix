#!/usr/bin/env bash
set -euo pipefail

# This script does the following:
# - When called without arguments, update all flake inputs, including nixpkgs.
# - With --refresh, resolve input changes and regenerate files without updating inputs.
# - Print version updates of pinned pkgs like so:
#     Pkg updates in nixpkgs unstable:
#     bitcoin: 0.20.0 -> 0.21.1
#     btcpayserver: 1.1.0 -> 1.1.2
# - Write ../pkgs/pinned.nix with packages from unstable nixpkgs.
# - Write ../versions.json with pinned and local package versions and channels.
# - Write ../docs/versions-table.md, the package versions table of the docs.

forceRun=
refreshOnly=
for arg in "$@"; do
    case $arg in
        -f)
            forceRun=1
            ;;
        --refresh)
            refreshOnly=1
            ;;
        *)
            echo "Usage: $0 [-f] [--refresh]" >&2
            exit 1
            ;;
    esac
done

# cd to script dir
cd "${BASH_SOURCE[0]%/*}"

if [[ $(nix flake 2>&1) != *"requires a sub-command"* ]]; then
    echo "Error. This script requires nix flake support."
    echo "https://nixos.wiki/wiki/Flakes#Installing_flakes"
    exit 1
fi

if [[ ! $forceRun ]] && ! git diff --quiet ../flake.{nix,lock}; then
    echo "error: flake.nix/flake.lock have changes. Run with option -f to ignore."
    exit 1
fi

versions=$(nix eval --json -f update-flake.nix versions)

## Uncomment the following to generate a version change message for testing
# versions=$(echo "$versions" | sed 's|1|0|g')

if [[ ! $refreshOnly ]]; then
    echo "Updating flake 'nixos-search'"
    nix flake update --flake ../test/nixos-search
    echo "Updating main flake"
    nix flake update --flake ..
else
    # Resolve input changes while retaining existing locks wherever possible.
    nix flake lock ..
fi

echo
nix eval --raw -f update-flake.nix --argstr prevVersions "$versions" showUpdates; echo

pinned=../pkgs/pinned.nix
# Compare the raw eval output byte for byte, like test/ci/check-versions.sh
pinnedNew=$(mktemp)
trap 'rm -f "$pinnedNew"' EXIT
nix eval --raw -f update-flake.nix --argstr prevVersions "$versions" pinnedFile > "$pinnedNew"
if ! cmp -s "$pinnedNew" "$pinned"; then
    cp "$pinnedNew" "$pinned"
    echo
    echo "Updated pinned.nix"
fi

nix eval --json -f update-flake.nix versionsFile |
    nix shell --inputs-from .. nixpkgs#jq -c jq . > ../versions.json
./gen-docs-versions.sh > ../docs/versions-table.md
