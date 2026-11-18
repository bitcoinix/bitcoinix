{ config, ... }:

let
  inherit (config.services) clightning;
in
{
  condition = clightning.enable;
  message = ''
    The Core Lightning data dir (`services.clightning.dataDir`) is no longer
    writable by group `${clightning.group}`. Group members, like the operator user
    and BTCPay Server with `lightningBackend = "clightning"`, can still use the
    RPC socket and read the files they could read before. A script that creates,
    renames or deletes entries in the data dir as a group member now fails. Run
    it as user `${clightning.user}` or as root instead.
  '';
}
