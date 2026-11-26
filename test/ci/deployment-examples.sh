#!/usr/bin/env bash

# Build the deployment examples in ../../examples with their deployment tools.
# The examples pin a bitcoinix release; this script builds them against this
# checkout instead. The krops example is also deployed to a QEMU VM
# (../../examples/deploy-krops.sh), which requires KVM.
#
# This script can also be run locally for testing:
#   ./deployment-examples.sh [flakes|colmena|krops]...
#
# This script leaves no persistent traces on the host system outside of /nix/store,
# except for the secrets of the krops example in the gitignored examples/secrets.

set -euo pipefail

repo=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
tmpDir=$(mktemp -d)
trap 'rm -rf "$tmpDir"' EXIT

# The examples set the configVersion of the release they pin. Build them with the
# checkout's latest released version, retaining development warnings.
configVersion=
getConfigVersion() {
    if [[ ! $configVersion ]]; then
        configVersion=$(nix eval --raw --file "$repo/version.nix")
        [[ $configVersion =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
    fi
}

# Copy an example, so that locking doesn't write to the checkout, set its
# configVersion and lock its bitcoinix input to this checkout
prepareExample() {
    getConfigVersion
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

# Deployment with krops (legacy)
deployKrops() {
    if [[ -v GITHUB_ACTIONS && ! -e /dev/kvm ]]; then
        >&2 echo "No KVM available on VM host."
        exit 1
    fi
    nixpkgs=$(nix eval --raw --impure --expr "(import $repo/pkgs/nixpkgs-pinned.nix).nixpkgs")
    export NIX_PATH="nixpkgs=$nixpkgs:nix-bitcoin=$repo"

    # Check that the krops sources exclude every symlink in nixpkgs and in the
    # tracked files of bitcoinix (see the TODO-EXTERNAL in examples/krops/sources.nix)
    excludedFilters=$(
        nix eval --impure --raw --expr "
          let
            sources = import $repo/examples/krops/sources.nix {
              extraSources = {};
              krops = (import <nix-bitcoin> {}).krops;
            };
            excludes = src: builtins.concatStringsSep \"\n\" (
              map (f: \"\${src}\t\${f.pattern}\")
                (builtins.filter (f: f.type == \"exclude\") sources.\${src}.file.filters)
            );
          in excludes \"nixpkgs\" + \"\n\" + excludes \"nix-bitcoin\" + \"\n\"
        "
    )
    checkSymlinksExcluded() {
        local source=$1 symlinks=$2 excluded missing
        excluded=$(awk -F '\t' -v src="$source" '$1 == src { print $2 }' <<< "$excludedFilters")
        missing=$(comm -23 <(sort <<<"$symlinks") <(sort <<<"$excluded"))
        if [[ $missing ]]; then
            >&2 echo "error: examples/krops/sources.nix doesn't exclude these symlinks of source $source:"
            >&2 echo "$missing"
            exit 1
        fi
    }
    checkSymlinksExcluded nixpkgs "$(cd "$nixpkgs" && find . -type l | sed 's|^\.||')"
    checkSymlinksExcluded nix-bitcoin "$(
        git -C "$repo" ls-files --format='%(objectmode) /%(path)' | sed -n 's|^120000 ||p'
    )"

    # Build the deploy script of the user-facing example
    nix-build --no-out-link "$repo/examples/krops/deploy.nix"

    "$repo/examples/deploy-krops.sh"
}

if [[ $# == 0 ]]; then
    set -- flakes colmena krops
fi
for example in "$@"; do
    echo "Building deployment example '$example'"
    case $example in
        flakes) (buildFlakes) ;;
        colmena) (buildColmena) ;;
        krops) (deployKrops) ;;
        *) >&2 echo "Unknown deployment example '$example'"; exit 1 ;;
    esac
done
