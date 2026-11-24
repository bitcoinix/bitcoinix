#### Core Lightning replication dirs no longer writable by its group

With `services.clightning.replication`, the local replica dir (with
`local.setupDirectory`) and `/var/cache/clightning-replication` (with
`sshfs.destination` or `encrypt`) now have mode `0750` instead of `0770`, like the Core
Lightning data dir. Members of the clightning group, like the operator user, can still
read them, but only clightning writes there. See
[Upgrading to config version 0.2.1](../../upgrading/0.2.1/core-lightning-replication-dirs-no-longer-writable-by-its-group.md).
