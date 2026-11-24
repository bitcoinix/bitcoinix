#### Core Lightning replication dirs no longer writable by its group

With `services.clightning.replication`, two dirs now have mode `0750` instead of
`0770`, like the Core Lightning data dir.

- `services.clightning.replication.local.directory`, when `local.setupDirectory` is
  on. It holds the replica, or with `encrypt` the encrypted replica.
- `/var/cache/clightning-replication`, with `sshfs.destination` or `encrypt`. It
  holds the mount points of SSHFS and gocryptfs.

Before, every member of the clightning group (`services.clightning.group`,
`clightning` by default) could create, rename and delete entries in them. The group
can hold the operator user (with `nix-bitcoin.operator.enable`), BTCPay Server's user
(with `services.btcpayserver.lightningBackend = "clightning"`) and the users that you
add to it.

The deployment sets the new modes, and clightning removes write access of the group
and others from the local dir again when it starts. If the local dir belongs to
another user, for example on a share that you set up yourself, clightning can't change
it. Then make the clightning user its owner and give it mode `0750`, on the share's
server or in its mount options if needed. A server needs the user's numeric id, which
`id -u clightning` prints on this node. Check that clightning can still write there,
for example with `runuser -u clightning -- test -w <local.directory> && echo writable`.

Group members can still read these dirs. A script that writes there as a group member
now fails. Run it as the clightning user (`services.clightning.user`, `clightning` by
default) or as root.

clightning creates its files there as the clightning user. After you deploy, list the
entries that another user created. Stop the replication first, because root can't look
into the mounts, but keep the replica's disk or share mounted. Then run this as root.
Use your `local.directory` and `services.clightning.user`, and leave out what your
config doesn't use.

```shell
systemctl stop clightning-replication-mounts clightning
find /var/backup/clightning /var/cache/clightning-replication ! -user clightning
```

On a share where root can't read the local dir, run its `find` as the clightning user
with `runuser -u clightning --`, or on the share's server with `! -uid <id>` and the
numeric id from above. `lost+found` and the entries that you created as root are fine.
Move every other entry out of these dirs, on the share's server if needed. Then start
clightning again with `systemctl start clightning`.
