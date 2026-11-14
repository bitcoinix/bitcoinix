{ config, lib, ... }:

with lib;
{
  condition = config.services.bitcoind.enable;
  message = let
    bitcoind = config.services.bitcoind;
  in ''
    bitcoind's RPC authentication cookie has moved from
    `${bitcoind.dataDir}/${optionalString bitcoind.regtest "regtest/"}.cookie`
    to `/run/bitcoind/.cookie`.

    Update external RPC clients and scripts that read the old cookie path.
    The bitcoin-cli installed by bitcoinix reads the new path from bitcoin.conf.
  '';
}
