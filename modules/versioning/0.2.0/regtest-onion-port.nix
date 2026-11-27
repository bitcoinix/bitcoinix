{ config, options, lib, ... }:

{
  condition = config.services.bitcoind.enable && config.services.bitcoind.network == "regtest"
    && (config.bitcoinix.onionServices.bitcoind.enable or false)
    && options.services.bitcoind.onionPort.highestPrio == (lib.mkOptionDefault null).priority;
  message = ''
    The default regtest onion target port has moved from 8334 to 18445.
    The bitcoinix Tor mapping follows the new port automatically. Update custom
    mappings that target 8334, or set `services.bitcoind.onionPort = 8334;` to keep that target.
  '';
}
