#### clightning requires the mount of its local replica

With `services.clightning.replication.local.directory`, `clightning` now doesn't
start while the disk or share under that directory isn't mounted. Before, it wrote
the replica to the filesystem below the mount point, usually the primary disk, without
a warning. This works only for mounts that systemd knows, like `fileSystems` entries.
See [Upgrading to config version 0.2.0](../../upgrading/0.2.0/clightning-requires-the-mount-of-its-local-replica.md).
