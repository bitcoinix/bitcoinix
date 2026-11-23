{ options, ... }:

{
  condition = options.services.bitcoind.sysperms.isDefined;
  message = ''
    `services.bitcoind.sysperms` has been removed. Bitcoin Core 25.0 removed
    this setting, so bitcoind ignored it. Remove the option from your configuration.
  '';
}
