#!/usr/bin/env bash
set -euo pipefail

scriptDir=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
cd "$scriptDir"

echo "Updating btcpayserver"
../../build-support/update-btcpay-package.sh btcpayserver deps.nix
