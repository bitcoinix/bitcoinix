#!/usr/bin/env bash
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/../../helper/run-in-nix-env" "coreutils git gnugrep gnused jq" "$@"

# Update krops in ./default.nix to the latest upstream release.
#
# Usage:
#   update.sh           # update ./default.nix
#   update.sh --check   # only report whether a newer release exists
#
# helper/update-flake.sh runs `update.sh --check`. Review the upstream changelog
# before updating.

repo=https://cgit.krebsco.de/krops
file=${BASH_SOURCE[0]%/*}/default.nix

check=
case ${1:-} in
    --check) check=1 ;;
    "") ;;
    *) echo "Usage: $0 [--check]" >&2; exit 1 ;;
esac

pinned=$(sed -nE 's/^ *version = "([^"]+)";$/\1/p' "$file")
[[ $pinned ]]

# Releases are tagged `v<version>`. Older releases used plain `<version>` tags,
# which are older than the pinned release and are ignored.
latest=$(
    git ls-remote --tags --refs "$repo" | cut -f 2 \
        | sed -nE 's|^refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$|\1|p' | sort -V | tail -1
)
[[ $latest ]]

if [[ $latest == "$pinned" ]]; then
    echo "krops $pinned is the latest release."
    exit 0
fi
if [[ $(printf '%s\n' "$pinned" "$latest" | sort -V | tail -1) != "$latest" ]]; then
    echo "error: pinned krops $pinned is newer than the latest release $latest." >&2
    exit 1
fi

changelog="$repo/tree/CHANGELOG.md?h=v$latest"
if [[ $check ]]; then
    echo "krops $latest is available (pinned: $pinned)."
    echo "Review $changelog and run ./pkgs/krops/update.sh."
    exit 0
fi

echo "Updating krops: $pinned -> $latest"
hash=$(nix flake prefetch --json "git+$repo?ref=refs/tags/v$latest" | jq -r .hash)
[[ $hash == sha256-* ]]
sed -i -E \
    -e "s|^( *version = )\"[^\"]+\";$|\1\"$latest\";|" \
    -e "s|^( *hash = )\"[^\"]+\";$|\1\"$hash\";|" \
    "$file"
grep -q "version = \"$latest\";" "$file"
grep -q "hash = \"$hash\";" "$file"
echo "Updated $file. Review $changelog"
