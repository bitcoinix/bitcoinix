{ config, ... }:

{
  # Secret symlinks and custom generation commands cannot be inspected at
  # evaluation time, so notify everyone using the affected setup service.
  condition = config.nix-bitcoin.setupSecrets;
  message = ''
    setup-secrets now runs in a sandbox with no IP network access and only
    the secrets directory and private temporary directories writable.
    Before deploying, replace declared secret symlinks to external files
    with files in `nix-bitcoin.secretsDir`, and adapt custom
    `nix-bitcoin.generateSecretsCmds` to the sandbox or supply secrets before
    setup-secrets starts.

    A failed setup now leaves the entire secrets directory accessible only
    to root even when `nix-bitcoin.generateSecrets` is false. Repair the
    missing or invalid secret and rerun setup to restore service access.
  '';
}
