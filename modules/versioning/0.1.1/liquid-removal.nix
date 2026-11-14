{ options, ... }:

{
  condition = options.services.liquidd.isDefined
    || options.services.btcpayserver.lbtc.isDefined;
  message = ''
    Liquid support, including the Elements daemon, liquid-swap and BTCPay Server's
    LBTC integration, has been removed.

    If you used Liquid, remove `services.liquidd`, `services.btcpayserver.lbtc` and
    any Liquid-specific onion service or network namespace settings from your
    configuration. Your Liquid wallets stay in the former data directory
    (default: /var/lib/liquidd), but the backups service no longer includes it.
  '';
}
