{ config, lib, ... }:

with lib;
{
  condition = let
    whitelist = config.services.bitcoind.rpc.users.btcpayserver.rpcwhitelist;
  in config.services.btcpayserver.enable
    # An empty list disables the whitelist for this user.
    && whitelist != [] && !(elem "scantxoutset" whitelist);
  message = ''
    BTCPay Server's wallet UTXO scan is now disabled by default. The
    `btcpayserver` RPC user no longer has permission to call `scantxoutset`,
    because a scan can keep bitcoind busy for minutes.

    To keep using this feature, add:
      services.bitcoind.rpc.users.btcpayserver.rpcwhitelist = [ "scantxoutset" ];

    Otherwise, leave it disabled and acknowledge the change by updating
    `nix-bitcoin.configVersion`.
  '';
}
