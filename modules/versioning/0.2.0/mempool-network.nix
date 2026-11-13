{ config, ... }:

{
  condition = config.services.mempool.enable && config.services.bitcoind.network == "regtest";
  message = ''
    Mempool now uses regtest in both its backend and frontend when
    services.bitcoind.network is "regtest", instead of identifying as mainnet.
    Mempool automatically clears disk caches labelled mainnet and reloads
    data from the configured backend. Review any custom frontend network
    settings or staticContentRoot, then reload the web interface.
  '';
}
