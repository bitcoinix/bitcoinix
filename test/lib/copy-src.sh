# Re-run run-tests.sh in a snapshot copy of the source.
# Copy into a fresh private directory on every run. A shared cache at a fixed
# /tmp path can be replaced by another local user, and the tests may run as root.

tmp=$(mktemp -d '/tmp/nix-bitcoin-src.XXXXX')
trap 'rm -rf "$tmp"' EXIT

# shellcheck disable=SC2154
rsync -a "$scriptDir/../" "$tmp/src"
echo "Copied src"

# shellcheck disable=SC2154
_nixBitcoinInCopiedSrc=1 "$tmp/src/test/run-tests.sh" "${args[@]}"
