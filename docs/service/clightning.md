# Core Lightning

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

Core Lightning (CLN), formerly c-lightning, uses the `services.clightning`
options, `clightning` systemd service, and `lightning-cli` command in bitcoinix.

## Plugins
There are a number of [plugins](https://github.com/lightningd/plugins) available for Core Lightning.
See [`README: Features → Core Lightning`](https://github.com/bitcoinix/bitcoinix/blob/master/README.md) or the
`services.clightning.plugins` [module options](../options.md) for a complete list.

You can activate and configure these plugins like so:

```nix
services.clightning = {
  enable = true;
  plugins = {
    clboss.enable = true;
    clboss.min-onchain = 40000;
  };
};
```

Please have a look at the module for a plugin (e.g. [clboss.nix](https://github.com/bitcoinix/bitcoinix/blob/master/modules/clightning-plugins/clboss.nix)) to learn its configuration options.

### Currency rates

Enable the Rust [cln-currencyrate plugin](https://github.com/ElementsProject/lightning/tree/master/plugins/currencyrate-plugin):

```nix
services.clightning.plugins.currencyrate.enable = true;
```

Use `lightning-cli currencyconvert 100 USD` to convert a fiat amount into
millisatoshis, `lightning-cli listcurrencyrates USD` to list source prices in
USD per BTC, or `lightning-cli currencyrate USD` to get the median rate.

For custom price sources, set `currencyrate-add-source` and
`currencyrate-disable-source` in `services.clightning.extraConfig`; see the
[upstream plugin documentation](https://github.com/ElementsProject/lightning/tree/master/plugins/currencyrate-plugin).
The plugin follows CLN's configured proxy and shares its service sandbox and
network namespace.

If you used the former Python plugin, follow the
[currencyrate migration instructions](../upgrading/0.1.5.md).

### Trustedcoin
When `services.clightning.tor.proxy` is enabled, [trustedcoin](https://github.com/nbd-wtf/trustedcoin)
also uses Tor for all external connections by default.
In this case, connections to block explorers can sometimes get blocked.

An example of Core Lightning log error output when connections are getting blocked:
```
lightningd[5138]: plugin-trustedcoin estimatefees error: https://blockstream.info/api error: 403 Forbidden
lightningd[4933]: plugin-trustedcoin getblock error: got something that isn't a block hash: <html><head>...
```

To work around this and connect via clearnet instead, set this option:
```nix
services.clightning.plugins.trustedcoin.tor.proxy = false;
```
This also disables `services.clightning.tor.enforce`, so the whole `clightning` service
is no longer restricted to Tor.

<a id="clightning-database-replication"></a>

## Core Lightning database replication

Core Lightning can write a live copy of its database to a local path
or to a remote SSH target (mounted via SSHFS).
Optionally, the copy can be encrypted with `gocryptfs`.
See the [module](https://github.com/bitcoinix/bitcoinix/blob/master/modules/clightning-replication.nix)
for all options.

The replica filename is `lightningd-signet.sqlite3` on signet and
`lightningd-testnet4.sqlite3` on testnet4. Mainnet and regtest both use
`lightningd.sqlite3`. Give those two networks separate replication destinations
to keep one from overwriting the other's replica.

`clightning` requires the replication target: it doesn't start while the target is
unavailable, e.g. when the SSHFS mount fails. For a local directory, this works only
when systemd knows the mount that holds the directory. See
[Local directory target](#local-directory-target).

Also back up:
- the static file `hsm_secret` (`/var/lib/clightning/bitcoin/hsm_secret` by default).
  The `services.backups` module includes it.
- with `encrypt`, the password `$secretsDir/clightning-replication-password`. Without it,
  the copy can't be decrypted. `services.backups` includes the secrets dir only
  with `bitcoinix.generateSecrets`.

### Remote target via SSHFS

1. Add this to your configuration:
   ```nix
   services.clightning.replication = {
     enable = true;
     sshfs.destination = "user@hostname:directory";
     # This is optional
     encrypt = true;
   };
   programs.ssh.knownHosts."hostname".publicKey = "<contents of /etc/ssh/ssh_host_ed25519_key.pub on the target>";
   ```

   Leave out the `encrypt` line if you want to store data on your destination
   in plaintext.\
   Adjust `user`, `hostname` and `directory` as necessary. `directory` is relative to
   the home of `user`. If the target's SSH server doesn't listen on port 22, set
   `sshfs.port` and use `"[hostname]:<port>"` as the `knownHosts` name.

   The `knownHosts` entry is required: the mount runs without a terminal, so SSH
   can't ask you to accept an unknown host key and the mount fails.
   Read the host key on the target itself, not with `ssh-keyscan` from the node,
   which trusts whatever host answers.
   Don't add `StrictHostKeyChecking=no` to `sshfs.sshOptions`. It allows any host
   on the network path to impersonate the target and receive the database,
   in plaintext without `encrypt`.

2. Deploy. With `bitcoinix.generateSecrets`, this creates the SSH key
   `$secretsDir/clightning-replication-ssh-key`.
   `clightning` starts only once the target accepts this key (step 3).

3. To allow SSH access from the bitcoinix node to the target node, either
   use the remote node config below, or copy the contents of `$secretsDir/clightning-replication-ssh-key.pub`
   to the `authorized_keys` file of `user` (or use `ssh-copy-id`).
   Then run `systemctl restart clightning` as root.

4. You can restrict the bitcoinix node's capabilities on the SSHFS target
   to SFTP access in a chroot.
   To implement this on NixOS, add the following to the NixOS configuration of
   the SSHFS target node:
   ```nix
   systemd.tmpfiles.rules = [
     # Because this directory is chrooted by sshd, it must only be writable by user/group root
     "d /var/backup/nb-replication 0755 root root - -"
     "d /var/backup/nb-replication/writable 0700 nb-replication - - -"
   ];

   services.openssh = {
     extraConfig = ''
       Match user nb-replication
         ChrootDirectory /var/backup/nb-replication
         AllowTcpForwarding no
         AllowAgentForwarding no
         ForceCommand internal-sftp
         PasswordAuthentication no
         X11Forwarding no
     '';
   };

   users.users.nb-replication = {
     isSystemUser = true;
     group = "nb-replication";
     shell = "${pkgs.coreutils}/bin/false";
     openssh.authorizedKeys.keys = [ "<contents of $secretsDir/clightning-replication-ssh-key.pub>" ];
   };
   users.groups.nb-replication = {};
   ```

   With this setup, the corresponding `sshfs.destination` on the bitcoinix
   node is `"nb-replication@hostname:writable"`.

### Local directory target

1. Add this to your configuration:
   ```nix
   services.clightning.replication = {
     enable = true;
     local.directory = "/var/backup/clightning";
     encrypt = true;
   };
   ```

   Leave out the `encrypt` line if you want to store data in
   `local.directory` in plaintext.

2. Deploy

Core Lightning will now replicate database files to `local.directory`. This
can be used to replicate to an external HDD by mounting it at path
`local.directory`.

`clightning` requires the mounts for `local.directory`. With `encrypt`,
`clightning-replication-mounts` requires them too. While the disk isn't mounted,
`clightning` doesn't start, so the replica can't land on the primary disk.
systemd can only wait for the mounts it knows, so declare the disk in `fileSystems`:
```nix
fileSystems."/var/backup/clightning" = {
  device = "/dev/disk/by-uuid/<uuid of the disk's filesystem>";
  fsType = "ext4";
  # Boot without the disk. clightning stays stopped then.
  options = [ "nofail" ];
};
```
systemd finds the mounts from the path as written and doesn't follow symlinks.
So set `local.directory` to the mount point or a directory below it, not to a
symlink. A directory on the root filesystem has no mount to wait for.

### Custom remote destination

Follow the steps in section "Local directory target" above and mount a custom remote
destination (e.g., an NFS or SMB share) to `local.directory`. Declare the share in
`fileSystems`, so that `clightning` doesn't start without it.\
You might want to disable `local.setupDirectory` in order to create the mount directory
yourself with custom permissions.
