{ options, ... }:

{
  condition = options.services.bitcoind.regtest.isDefined
    || options.services.bitcoind.makeNetworkName.isDefined;
  message = ''
    services.bitcoind.regtest has been replaced by the
    services.bitcoind.network option. Replace true with services.bitcoind.network = "regtest";
    or remove the old option for mainnet (the default).
    The makeNetworkName helper has also been removed. Select network-specific
    values using config.services.bitcoind.network instead.
  '';
}
