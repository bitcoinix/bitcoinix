{ config, ... }:

{
  # Only a directory below a mount that systemd knows changes behavior. systemd
  # also knows mounts that aren't in `fileSystems`, like `systemd.mounts` entries.
  # So notify every user of a local replica directory.
  condition = let
    inherit (config.services) clightning;
  in clightning.enable && clightning.replication.enable
     && clightning.replication.local.directory != null;
  message = ''
    clightning now requires the mounts for
    `services.clightning.replication.local.directory`. While the disk or share
    under that path isn't mounted, clightning doesn't start. Before, it wrote the
    replica to the filesystem below the mount point, usually the primary disk.
    With `encrypt`, this also applies to clightning-replication-mounts. systemd
    can only wait for the mounts it knows, so declare the disk or share in
    `fileSystems`. A directory on the root filesystem starts as before. Stopping
    or restarting the mount now also stops or restarts clightning.
  '';
}
