{ config, lib, ... }:

with lib;
let
  users = filter (name: config.services.${name}.enable) [ "clightning" "mempool" ];
  list = f: concatMapStringsSep ", " f users;
in
{
  # No option marks a bitcoind on another node: the bitcoind-remote preset only
  # changes the bitcoind unit. And configs that supply their own secrets have to
  # act either way. So notify every config with one of these services.
  condition = users != [];
  message = ''
    These services now connect to bitcoind as their own RPC users instead of
    `public`: ${list (name: "${name} as `${config.services.bitcoind.rpc.users.${name}.name}`")}.
    The methods that only they need no longer reach the other services of
    `public`. Each user needs its own password and HMAC in the secrets dir:
    ${list (name: "`bitcoin-rpcpassword-${name}` and `bitcoin-HMAC-${name}`")}.
  '' + (if config.nix-bitcoin.generateSecrets then ''
    `nix-bitcoin.generateSecrets` creates them. If bitcoind runs on this node,
    there's nothing else to do.
  '' else ''
    Create them before deploying, unless the krops deployment shell creates
    your secrets.
  '') + ''
    With bitcoind on another node, also create these RPC users there, with
    the whitelists in ${list (name: "`services.bitcoind.rpc.users.${name}.rpcwhitelist`")}.
    Remove `getblockfrompeer` and `gettxoutsetinfo` from the whitelist of the
    public user there, if it has them, whatever this config enables.
  '' + optionalString config.services.btcpayserver.enable ''
    Set the whitelist of the BTCPay Server user there again from
    `services.bitcoind.rpc.users.btcpayserver.rpcwhitelist`. It builds on the
    public whitelist, so with mempool it had `gettxoutsetinfo` too.
  '';
}
