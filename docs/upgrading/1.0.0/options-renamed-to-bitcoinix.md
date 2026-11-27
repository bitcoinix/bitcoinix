#### Options renamed to bitcoinix

The module options moved from `nix-bitcoin.*` to `bitcoinix.*`. The old prefix still
works, but it will be removed in a later release:

- Setting any `nix-bitcoin.*` option shows one evaluation warning that lists the files.
  Rename the prefix there, for example `nix-bitcoin.configVersion` to
  `bitcoinix.configVersion`. `mkDefault` and `mkForce` keep working under either prefix.
- Reading `config.nix-bitcoin` in your own modules shows a warning. Read
  `config.bitcoinix` instead, for example `config.bitcoinix.lib`.
- Code that inspects option metadata under the old prefix, like
  `options ? nix-bitcoin.wireguard` or `options.nix-bitcoin.<name>.definitions`, no
  longer matches. Use `options.bitcoinix` there.
- An undeclared option under the old prefix is reported under its new name, for
  example ``The option `bitcoinix.foo' does not exist``.

Runtime names don't change: `nix-bitcoin-secrets.target`, the secrets directory,
`nix-bitcoin-wg-connect`, and the service users and groups keep their names.
