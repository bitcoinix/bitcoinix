{ options, ... }:

{
  condition = options.services.bitcoind.regtest.isDefined;
  message = ''
    services.bitcoind.regtest has been replaced by the deployment-wide
    nix-bitcoin.network option. Replace true with nix-bitcoin.network = "regtest";
    or remove the old option for mainnet (the default).
  '';
}
