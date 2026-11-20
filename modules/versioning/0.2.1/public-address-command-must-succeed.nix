{ config, lib, ... }:

let
  cmd = name: config.services.${name}.getPublicAddressCmd;
  # ../../onion-services.nix sets this command for a public onion service. The services
  # already failed without their onion address, so only a custom command changes.
  onionCmd = name: "cat ${config.bitcoinix.onionAddresses.dataDir}/services/${name}";
  hasCustomCmd = name: config.services.${name}.enable && cmd name != "" && cmd name != onionCmd name;
  services = lib.filter hasCustomCmd [ "bitcoind" "lnd" "clightning" ];
in
{
  condition = services != [ ];
  message = lib.concatMapStrings (name: ''
    ${name} now fails to start when `services.${name}.getPublicAddressCmd` fails.
    Before, ${name} used what the command printed, also when the command failed.
  '') services;
}
