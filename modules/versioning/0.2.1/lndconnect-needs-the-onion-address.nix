{ config, lib, ... }:

let
  svc = config.services;
  # `or false`: a config can remove ../../lndconnect.nix with `disabledModules`
  lndOnion = (svc.lnd.enable or false) && (svc.lnd.lndconnect.enable or false)
    && (svc.lnd.lndconnect.onion or false);
  clnrestOnion = (svc.clightning.plugins.clnrest.enable or false)
    && (svc.clightning.plugins.clnrest.lnconnect.enable or false)
    && (svc.clightning.plugins.clnrest.lnconnect.onion or false);
  commands = lib.optional lndOnion "`lndconnect`" ++ lib.optional clnrestOnion "`lnconnect-clnrest`";
  subject = "${lib.concatStringsSep " and " commands} now ${if lib.length commands > 1 then "fail" else "fails"}";
in
{
  condition = lndOnion || clnrestOnion;
  message = ''
    With `onion`, ${subject} when the onion address file is missing or
    unreadable. Before, the lndconnect tool then looked up the node's public
    IP over clearnet and printed a URL with that IP. An empty `--host` is now
    an error. With `onion`, `--localhost` and `--localip` only worked together
    with an empty `--host` or while the onion address was missing, so those
    calls fail now too. For a local URL, pass `--host 127.0.0.1` or `--host`
    with the node's LAN IP.
  '';
}
