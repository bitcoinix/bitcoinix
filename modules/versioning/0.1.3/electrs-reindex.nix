{ config, lib, ... }:

with lib;
{
  condition = config.services.electrs.enable;
  message = let
    dbPath = "${config.services.electrs.dataDir}/${config.services.bitcoind.makeNetworkName "bitcoin" "regtest"}";
  in ''
    electrs 0.12.0 uses a new index format and must rebuild its index from scratch.
    It does not convert or delete the old index: until it is removed, electrs
    refuses to start.
    Reindexing takes from a few hours to about a day, depending on your hardware.
    electrs accepts connections while it indexes but answers with incomplete history
    and balances until indexing has finished. The same applies to mempool if it
    uses electrs.

    To upgrade, delete the old index before deploying:
      systemctl stop electrs && rm -r ${escapeShellArg dbPath}
    Then deploy the new system config to your node.
    If you roll back to the previous config after electrs 0.12 has started once,
    also remove the marker file ${escapeShellArg "${dbPath}.bindex"}. Otherwise the index check is
    skipped on the next upgrade.

    electrs now requires Bitcoin Core 31 or later and reads blocks through
    bitcoind's REST interface, which is enabled automatically
    (`services.bitcoind.rest.enable`). REST is served without
    authentication on the RPC port to every source in `services.bitcoind.rpc.allowip`.
    If that list contains sources other than localhost and bitcoinix's network
    namespaces, evaluation fails. Remove them, or set
    `services.bitcoind.rest.allowNonLocal = true` only if these sources may read
    blocks, transactions, the UTXO set and the mempool without authentication.
    `rpcallowip` or `includeconf` in `services.bitcoind.extraConfig` also fail
    evaluation (see `services.bitcoind.rest.allowUncheckedConfig`).
  '';
}
