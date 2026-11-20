{ config, ... }:

{
  condition = config.services.mempool.enable
    && config.services.mempool.settings.CORE_RPC.PASSWORD or null != null;
  message = ''
    `services.mempool.settings.CORE_RPC.PASSWORD` is no longer accepted, because
    mempool's settings are copied to the world-readable Nix store. Remove it and
    save the password to `${config.bitcoinix.secretsDir}/bitcoin-rpcpassword-mempool`.
    Since 0.2.0, mempool connects to bitcoind as its own RPC user with this password.
  '';
}
