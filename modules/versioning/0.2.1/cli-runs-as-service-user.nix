{ config, ... }:

let
  inherit (config.services) bitcoind;
in
{
  condition = bitcoind.enable;
  message = ''
    When root runs `bitcoin-cli`, it now runs as user `${bitcoind.user}`. This is
    like `lncli`, which runs as the lnd user. So a call as root that passes a file
    that only root can read, for example with `bitcoin-cli -rpccookiefile`, now
    fails. `bitcoin-cli` reads the config from the Nix store and no longer reads
    `bitcoin.conf` in the data dir. With the `bitcoind-remote.nix` preset, the
    credentials for the remote node are now in `/run/bitcoind/.cookie`.
  '';
}
