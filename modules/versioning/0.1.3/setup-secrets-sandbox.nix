{ config, ... }:

{
  # Secret symlinks and custom generation commands cannot be inspected at
  # evaluation time, so notify everyone using the affected setup service.
  condition = config.bitcoinix.setupSecrets;
  message = ''
    setup-secrets now runs in a sandbox with no IP network access and only
    the secrets directory and private temporary directories writable.
    Before deploying, replace declared secret symlinks to external files
    with files in `bitcoinix.secretsDir`, and adapt custom
    `bitcoinix.generateSecretsCmds` to the sandbox or supply secrets before
    setup-secrets starts.

    A failed setup now leaves the entire secrets directory accessible only
    to root even when `bitcoinix.generateSecrets` is false. Repair the
    missing or invalid secret and rerun setup to restore service access.
  '';
}
