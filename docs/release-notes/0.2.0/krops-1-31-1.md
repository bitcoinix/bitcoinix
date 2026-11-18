#### krops 1.31.1

The [krops deployment](../../install.md#5-alternative-deploy-with-krops-legacy) uses krops
1.31.1 instead of 1.26.2 (see the
[changelog](https://cgit.krebsco.de/krops/tree/CHANGELOG.md?h=v1.31.1)). The commands
of the deployment shell don't change. Behavior changes for existing deployments:

- Names of `extraSources` may contain only letters, digits and `._-`, must not start
  with `-` and must not be `.`, `..` or `.populate`. Other names, e.g.
  `"nixos/networking.nix"`, fail evaluation.
- If the node has `/etc/nixos/flake.nix`, krops runs `nixos-rebuild` with `--no-flake`
  and deploys the synced configuration in `/var/src`.
- If a source's path on the node, e.g. `/var/src/secrets`, is a symlink, krops removes
  the symlink and syncs to that path instead of into the symlink's target. If you
  linked `/var/src/secrets` to an encrypted volume, mount the volume at
  `/var/src/secrets` instead before you deploy. Otherwise krops writes your secrets
  to the file system of `/var/src`.
- krops 1.31 pipes `nixos-rebuild` through `nix-output-monitor` if it's installed on
  the node. The deployment then reports success even if evaluation or activation
  failed. bitcoinix's krops therefore defaults `useNixOutputMonitor` of `writeDeploy`
  to `false`, which keeps the previous output and exit status.
- krops reuses one SSH connection per deployment. bitcoinix patches krops to keep the
  connection's socket in `/tmp`, because the upstream path is too long for macOS or for
  an onion host, which made the deployment fail.
