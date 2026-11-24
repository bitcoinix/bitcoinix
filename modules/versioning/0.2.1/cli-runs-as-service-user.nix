{ config, lib, ... }:

let
  inherit (config.services) bitcoind clightning;
in
{
  condition = bitcoind.enable;
  message = ''
    When root runs `bitcoin-cli`, it now runs as user `${bitcoind.user}`.
  '' + lib.optionalString clightning.enable ''
    When root runs `lightning-cli` or `lnconnect-clnrest`, they run as user
    `${clightning.user}`.
  '' + ''
    This is like `lncli`, which runs as the lnd user. So a call as root that
    passes a file that only root can read, for example with
    `bitcoin-cli -rpccookiefile`, now fails. `bitcoin-cli` reads the config from
    the Nix store and no longer reads `bitcoin.conf` in the data dir. With the
    `bitcoind-remote.nix` preset, the credentials for the remote node are now in
    `/run/bitcoind/.cookie`.
  '' + lib.optionalString clightning.enable ''
    `lnconnect-clnrest` reads the admin rune and clnrest's cert only from
    regular files of user `${clightning.user}`.
  '';
}
