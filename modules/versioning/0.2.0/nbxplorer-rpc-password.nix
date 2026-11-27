{ config, ... }:

let
  inherit (config.services) bitcoind nbxplorer;
in
{
  condition = config.services.btcpayserver.enable;
  message = ''
    NBXplorer's bitcoind RPC password
    (`${config.bitcoinix.secretsDir}/bitcoin-rpcpassword-btcpayserver`) is now
    readable only by NBXplorer's user `${nbxplorer.user}`, with mode 0400. Before,
    the user `${bitcoind.user}` and the group `${nbxplorer.group}` could read it too.
    BTCPay Server is in that group to read NBXplorer's API cookie, so it could read
    the password. A program that reads the password as another user now fails. Give
    it its own RPC user in `services.bitcoind.rpc.users`. If you manage the secret
    files outside bitcoinix, for example with `bitcoinix.secretsSetupMethod = "manual"`,
    make `${nbxplorer.user}` the owner of this file and set its mode to 0400.
  '';
}
