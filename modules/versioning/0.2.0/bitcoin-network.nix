{ config, ... }:

{
  # mkChangedOptionModule uses a non-boolean default for the old option.
  condition = builtins.isBool config.services.bitcoind.regtest;
  message = ''
    services.bitcoind.regtest has been replaced by the
    services.bitcoind.network option. Replace true with services.bitcoind.network = "regtest";
    or remove the old option for mainnet (the default).
  '';
}
