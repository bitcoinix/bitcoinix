#### clightning requires the mount of its local replica

`clightning` now requires the mounts for `services.clightning.replication.local.directory`.
With `encrypt`, `clightning-replication-mounts` requires them too. This changes
something only when a mount that systemd knows, like a `fileSystems` entry other
than `/`, holds the directory. While that mount is missing, `clightning` doesn't
start. Before, it started and wrote the replica to the filesystem below the mount
point, usually the primary disk. Then a failure of that disk took both copies.
Stopping or restarting the mount now also stops or restarts `clightning`.

Evaluation can't check which mount holds the directory, so it reports this change
for every local replica directory. If the directory is on the root filesystem, or
the replica's disk or share isn't declared, for example because you mount it by
hand, `clightning` starts as before. Declare the disk or share in `fileSystems`, as in
[Local directory target](../../services.md#local-directory-target), so that `clightning`
waits for it. systemd doesn't follow symlinks here, so if `local.directory` is a
symlink, set it to the target instead.

Deploying this change restarts `clightning` once, because its unit changes.

To check where the replica is, run `findmnt --target <local.directory>`. It names the
filesystem that holds the directory.
