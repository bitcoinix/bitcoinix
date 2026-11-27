#### Options renamed to bitcoinix

The module options moved from `nix-bitcoin.*` to `bitcoinix.*`, for example
`bitcoinix.configVersion`. Existing configurations keep working: `nix-bitcoin.*` is
now a deprecated alias that will be removed in a later release. Runtime names such as
`nix-bitcoin-secrets.target`, the secrets directory, `nix-bitcoin-wg-connect` and the
service users and groups are unchanged. See
[Upgrading to config version 1.0.0](../../upgrading/1.0.0/options-renamed-to-bitcoinix.md).
