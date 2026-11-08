#!/usr/bin/env bash
set -euo pipefail

cd "${BASH_SOURCE[0]%/*}"

cachixCache=bitcoinix

# Declare variables for shellcheck
driverDrvs=()
drivers=()
scenarioTests=()

echo '::group::Eval test drivers'
# Call ./test-info.nix
testInfo=$(time nix eval --raw --show-trace ../..#ciTestInfo)
# This sets variables `driverDrvs`, `drivers`, `scenarioTests`
eval "$testInfo"

for i in "${!drivers[@]}"; do
    echo "${drivers[$i]}"
    echo "${driverDrvs[$i]%^*}"
done
echo '::endgroup::'

if nix path-info --store "https://${cachixCache}.cachix.org" "${scenarioTests[@]}" &>/dev/null; then
    echo
    echo "All tests have already been built successfully:"
    printf '%s\n' "${scenarioTests[@]}"
    echo "run_scenario_tests=false" >> "$GITHUB_OUTPUT"
    exit 0
fi

echo "run_scenario_tests=true" >> "$GITHUB_OUTPUT"

# Without a signing key, no other runner can reuse this job's builds.
# Let the scenario jobs build their own dependencies without waiting for us.
if [[ -z ${CACHIX_SIGNING_KEY:-} ]]; then
    echo "No signing key: leaving driver builds to the scenario jobs."
    exit 0
fi

## Build test drivers

if nix path-info --store "https://${cachixCache}.cachix.org" "${drivers[@]}" &>/dev/null; then
    echo
    echo "All test drivers have already been built successfully:"
    exit 0
fi

echo '::group::Build test drivers'

if [[ -v GITHUB_ACTIONS ]]; then
    # Avoid cachix warning message
    mkdir -p ~/.config/nix && touch ~/.config/nix/nix.conf
    cachix use "$cachixCache"
fi

# Upload store paths as soon as they are created.
cachix watch-exec "$cachixCache" nix -- build --no-link --print-build-logs "${driverDrvs[@]}"
cachix push "$cachixCache" "${drivers[@]}"
