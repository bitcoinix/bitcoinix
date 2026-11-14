{ config, ... }:

{
  condition = config.services.clightning.plugins.rebalance.enable;
  message = ''
    The rebalance plugin now uses Core Lightning's askrene routing.
    Remove the `getroute_method` argument from `rebalance` RPC calls and
    remove `rebalance-getroute`, `rebalance-maxhops` and `rebalance-msatfactor`
    from your configuration; these settings are now ignored.
    The `rebalancereport` fields `getroute_method`, `maxhops_threshold` and
    `msatfactor` have been removed. Update scripts that read these fields.
  '';
}
