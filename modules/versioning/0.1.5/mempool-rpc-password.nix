{ config, ... }:

{
  condition = config.services.mempool.enable
    && config.services.mempool.settings.CORE_RPC.PASSWORD or null != null;
  message = ''
    `services.mempool.settings.CORE_RPC.PASSWORD` is no longer accepted, because
    mempool's settings are copied to the world-readable Nix store. Remove it and
    save the password to `${config.nix-bitcoin.secretsDir}/bitcoin-rpcpassword-public`.
  '';
}
