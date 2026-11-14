{ config, ... }:

{
  # Secret files can't be inspected at evaluation time, so notify everyone
  # using the affected setup service or lnd.
  condition = config.nix-bitcoin.setupSecrets || config.services.lnd.enable;
  message = ''
    setup-secrets now fails when a declared secret file is empty or isn't a
    regular file, as it does when one is missing. Before deploying, fill any
    empty secret file. For a secret that may be empty, set
    `nix-bitcoin.secrets.<name>.allowEmpty = true`.
    Secret generation doesn't replace an empty TLS, WireGuard or replication
    SSH private key, or a symlink to a missing file in its place: setup fails
    and says how to restore or replace it.
    With the bitcoind-remote preset and `nix-bitcoin.generateSecrets = false`,
    this includes the unused local `bitcoin-HMAC-*` files.
    lnd now stops when wallet.db isn't a regular file, for example a symlink
    to a missing file. While lnd has no wallet.db, it also stops when its seed
    file is a symlink to a missing file.
  '';
}
