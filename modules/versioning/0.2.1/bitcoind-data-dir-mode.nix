{ config, ... }:

let
  inherit (config.services) bitcoind;
in
{
  condition = bitcoind.enable;
  message = ''
    The bitcoind data dir (`services.bitcoind.dataDir`) is no longer writable
    by group `${bitcoind.group}`. Group members, like the operator user, can
    still use `bitcoin-cli` and read the files they could read before. A script
    that creates, renames or deletes entries in the data dir as a group member
    now fails. Run it as user `${bitcoind.user}` or as root instead.
  '';
}
