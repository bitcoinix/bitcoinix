#!/usr/bin/env bash
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/../helper/run-in-nix-env" "shellcheck findutils gnugrep" "$@"

# Shellcheck all bash sources in this repo

cd "${BASH_SOURCE[0]%/*}/.."
mapfile -t files < <(
    find . -path ./.git -prune -o -type f \( \
        -name '*.sh' -print -o \
        ! -name '*.*' -exec grep -lP '\A^#! */usr/bin/env (?:nix-shell|bash)' {} + \
    \) | sort
)
printf '%s\n' "${files[@]}"
shellcheck --external-sources --source-path=SCRIPTDIR --shell bash "${files[@]}"
