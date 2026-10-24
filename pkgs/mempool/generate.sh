#!/usr/bin/env nix-shell
#! nix-shell -i bash -p gnupg gnused jq curl
set -euo pipefail

# Use this to start a debug shell at the location of this statement
# . "${BASH_SOURCE[0]%/*}/../../helper/start-bash-session.sh"

version=3.3.2
# You can also specify a rev instead:
# rev=57eddac7f0b99b4fe84d91c0f4a50a4f7ccfe55f
owner=mempool
repo=https://github.com/$owner/mempool

cd "${BASH_SOURCE[0]%/*}"

updateSrc() {
    TMPDIR="$(mktemp -d /tmp/mempool.XXX)"
    trap 'rm -rf $TMPDIR' EXIT

    # Fetch and verify source
    src=$TMPDIR/src
    mkdir -p "$src"
    if [[ -v rev ]]; then
        # Fetch revision
        git -C "$src" init
        git -C "$src" fetch --depth 1 "$repo" "$rev:src"
        git -C "$src" checkout src
    else
        tag=v$version
        # Fetch and GPG-verify version tag
        git clone --depth 1 --branch "$tag" -c advice.detachedHead=false $repo "$src"
        git -C "$src" checkout tags/$tag
        export GNUPGHOME=$TMPDIR
        # Fetch wiz' key
        gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys 913C5FF1F579B66CA10378DBA394E332255A6173 2> /dev/null
        # Fetch mononaut's keys. Releases since v3.3.0 are signed by 523B596A78BB8495AA2EC45ABFD16BE592A9CD8D,
        # which is only published on GitHub.
        curl -fsS https://github.com/mononaut.gpg | gpg --import 2> /dev/null
        # Only accept signatures by these keys
        signer=$(git -C "$src" verify-tag --raw $tag 2>&1 | sed -nE 's/^\[GNUPG:\] VALIDSIG .* ([0-9A-F]{40})$/\1/p' || true)
        case $signer in
            913C5FF1F579B66CA10378DBA394E332255A6173|523B596A78BB8495AA2EC45ABFD16BE592A9CD8D) ;;
            *) echo "Tag $tag is not signed by a trusted key (signer: ${signer:-none})"; exit 1 ;;
        esac
        rev=$tag
    fi
    rm -rf "$src"/.git
    hash=$(nix hash path "$src")

    sed -i "
      s|\bversion = .*;|version = \"$version\";|
      s|\bowner = .*;|owner = \"$owner\";|
      /fetchFromGitHub/,/hash/ s|\bhash = .*;|hash = \"$hash\";|
    " default.nix
}

updateNodeModulesHash() {
    component=$1
    echo
    echo "Fetching node modules for mempool-$component"
    ../../helper/update-fixed-output-derivation.sh ./default.nix mempool-"$component".nodeModules "sourceRoot.*$component"
}

updateFrontendAssets() {
  . ./frontend-assets-update.sh
  echo
  echo "Fetching frontend assets"
  ../../helper/update-fixed-output-derivation.sh ./default.nix mempool-frontend.assets "frontendAssets"
}

updateRustGbtCargoDeps() {
    echo
    echo "Fetching rust-gbt cargo deps"
    ../../helper/update-fixed-output-derivation.sh ./default.nix mempool-rust-gbt.cargoDeps "fetchCargoVendor"
}

if [[ $# == 0 ]]; then
    # Each of these can be run separately
    updateSrc
    updateFrontendAssets
    updateNodeModulesHash backend
    updateNodeModulesHash frontend
    updateRustGbtCargoDeps
else
    "$@"
fi
