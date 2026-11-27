#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname -- "${BASH_SOURCE[0]}")/../.."
guide=docs/upgrading/0.2.1/lnd-empty-rpc-address.md
if [[ ! -f $guide ]]; then
    guide='docs/upgrading/0.2.1.md#empty-lnd-rpc-host'
fi

# Evaluating warnings can force LND's systemd unit before the migration notice
# prints. Check the error the operator actually gets, including the upgrade link.
for address in "" "[]"; do
    if output=$(LND_TEST_RPC_ADDRESS="$address" nix eval --impure --json --expr '
        let flake = builtins.getFlake (toString ./.);
        in (flake.inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ flake.nixosModules.default {
            boot.isContainer = true;
            system.stateVersion = "26.05";
            bitcoinix.configVersion = "0.2.0";
            bitcoinix.secretsSetupMethod = "manual";
            services.lnd = { enable = true; rpcAddress = builtins.getEnv "LND_TEST_RPC_ADDRESS"; };
          } ];
        }).config.warnings
    ' 2>&1); then
        echo "Expected LND to reject the empty RPC host '$address'." >&2
        exit 1
    fi
    for expected in "Invalid services.lnd.rpcAddress \"$address\"" '127.0.0.1' '::' '0.0.0.0' \
                    'IPv6-only' 'IPv4-only' 'subject alternative names' "$guide"; do
        if [[ $output != *"$expected"* ]]; then
            echo "Missing '$expected' in the LND evaluation error:" >&2
            echo "$output" >&2
            exit 1
        fi
    done
done
