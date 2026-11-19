#### Core Lightning data dir no longer writable by its group

The Core Lightning data dir now has mode `0750` instead of `0770`. Before, members of
the clightning group could write to it. So they could replace the config that
lightningd loads, or the network dir with `hsm_secret`. Group members keep the RPC
socket, which gives full control over the node. See
[Upgrading to config version 0.2.0](../../upgrading/0.2.0/core-lightning-data-dir-no-longer-writable-by-its-group.md).
