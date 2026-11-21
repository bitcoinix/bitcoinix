#!/usr/bin/env bash
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/../../helper/run-in-nix-env" "coreutils curl jq common-updater-scripts git gnupg" "$@"

# From nixpkgs' pkgs/by-name/nb/nbxplorer/util/update-common.sh, changed to update
# the packages in bitcoinix's pkgs/ dir. The update scripts of the BTCPay Server
# packages share it, so it lives outside their dirs.

# This script uses the following env vars:
# getVersionFromTags
# refetch

trap 'echo "Error at ${BASH_SOURCE[0]}:$LINENO"' ERR

pkgName=$1

: "${getVersionFromTags:=}"
: "${refetch:=}"

scriptDir=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
pkgsDir=$(realpath "$scriptDir"/..)

evalPkgs() {
  nix eval --impure --raw --expr "(with import \"$pkgsDir\" {}; $1)"
}

getRepo() {
  url=$(evalPkgs "$pkgName.src.meta.homepage")
  echo "$(basename "$(dirname "$url")")/$(basename "$url")"
}

getLatestVersionTag() {
  list-git-tags --url="https://github.com/$(getRepo)" 2>/dev/null \
    | sort -V | tail -1 | sed 's|^v||'
}

oldVersion=$(evalPkgs "$pkgName.version")
if [[ $getVersionFromTags ]]; then
  newVersion=$(getLatestVersionTag)
else
  newVersion=$(curl -s "https://api.github.com/repos/$(getRepo)/releases" | jq -r '.[0].name')
fi

if [[ $newVersion == "$oldVersion" && ! $refetch ]]; then
  echo "bitcoinix already has the latest version $newVersion"
  echo "Run this script with env var refetch=1 to re-verify the content hash via GPG"
  echo "and to recreate deps.json. This is useful for reviewing a version update."
  exit 0
fi

# Fetch release and GPG-verify the content hash
tmpdir=$(mktemp -d "/tmp/$pkgName-verify-gpg.XXX")
repo=$tmpdir/repo
trap 'rm -rf "$tmpdir"' EXIT
git clone --depth 1 --branch "v${newVersion}" -c advice.detachedHead=false "https://github.com/$(getRepo)" "$repo"
export GNUPGHOME=$tmpdir
importKey() {
  curl --fail --location --silent --show-error --retry 3 --retry-all-errors \
    "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$1" \
    | gpg --batch --import
}
# Fetch Nicolas Dorier's key (64-bit key ID: 6618763EF09186FE)
importKey AB4CFA9895ACA0DBE27F6B346618763EF09186FE
# Fetch Andrew Camilleri's key (64-bit key ID: 8E5530D9D1C93097)
importKey 836C08CF3F523BB7A8CB8ECF8E5530D9D1C93097
echo
echo "Verifying commit"
git -C "$repo" verify-commit HEAD
rm -rf "$repo"/.git
newHash=$(nix --extra-experimental-features nix-command hash path "$repo")
rm -rf "$tmpdir"
echo

# Update pkg version and hash
echo "Updating $pkgName: $oldVersion -> $newVersion"
(cd "$pkgsDir" && update-source-version "$pkgName" "$newVersion" "$newHash" --ignore-same-version)
echo

# Create deps file
"$(nix-build "$pkgsDir" -A "$pkgName.fetch-deps" --no-out-link)"
