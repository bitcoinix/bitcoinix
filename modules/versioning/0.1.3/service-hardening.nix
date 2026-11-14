{ config, lib, ... }:

with lib;
{
  # Custom hooks and plugins cannot be inspected at evaluation time, so
  # notify users of all services that receive the new restriction.
  condition = with config.services;
    any (service: service.enable) [
      bitcoind btcpayserver charge-lnd clightning electrs fulcrum
      lnd mempool nbxplorer rtl
    ]
    || config.nix-bitcoin.onionAddresses.access != {}
    || config.nix-bitcoin.onionAddresses.services != [];
  message = ''
    Services using `nix-bitcoin.lib.defaultHardening` now see /run and /dev
    (including /dev/shm) as read-only outside their allowed writable paths.
    Custom service hooks and plugins that write there can fail with
    "Read-only file system".

    Before deploying, check custom hooks and plugins. Use the service's
    runtime or data directory, or add a narrow `ReadWritePaths` exception
    for an existing path that must remain writable.
  '';
}
