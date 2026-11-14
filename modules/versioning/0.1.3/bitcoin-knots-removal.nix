{ options, ... }:

{
  condition = options.services.bitcoind.package.isDefined;
  message = ''
    Bitcoin Knots support and `services.bitcoind.package` have been removed.
    Remove `services.bitcoind.package` from your configuration. The daemon,
    bitcoin-cli and Core Lightning now use `nix-bitcoin.pkgs.bitcoind`
    (Bitcoin Core) directly.

    If you used Knots, review any Knots-specific settings in
    `services.bitcoind.extraConfig` before deploying.
  '';
}
