{ options, ... }:

{
  condition = options.services.bitcoind.regtest.isDefined;
  message = ''
    services.bitcoind.regtest has been replaced by the deployment-wide
    services.bitcoind.network option. Replace true with services.bitcoind.network = "regtest";
    or remove the old option for mainnet (the default).
  '';
}
