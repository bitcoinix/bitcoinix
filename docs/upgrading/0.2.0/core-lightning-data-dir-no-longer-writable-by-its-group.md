#### Core Lightning data dir no longer writable by its group

The Core Lightning data dir (`services.clightning.dataDir`, `/var/lib/clightning` by
default) now has mode `0750` instead of `0770`. Before, every member of the clightning
group (`services.clightning.group`, `clightning` by default) could create, rename and
delete entries in it. A member could swap the `config` file after `clightning.service`
wrote it and before lightningd read it, and make lightningd start a plugin of its
choice. Or it could replace the network dir with one that holds its own `hsm_secret`.
The group can hold the operator user (with `nix-bitcoin.operator.enable`), BTCPay
Server's user (with `services.btcpayserver.lightningBackend = "clightning"`) and the
users that you add to it.

The deployment sets the new mode. Group members can still use the RPC socket, for
example with `lightning-cli`, and read the files they could read before. The RPC socket
gives full control over the node, so add only trusted users to this group. A script
that writes to the data dir as a group member now fails. Run it as the clightning user
(`services.clightning.user`, `clightning` by default) or as root.

Every entry in the data dir belongs to the clightning user. To list the entries that
don't, run this as root. Use your `services.clightning.dataDir` and
`services.clightning.user` if you changed them:

```shell
find /var/lib/clightning ! -user clightning
```

If it lists an entry that you didn't create as root, a group member created it. Stop
clightning and check the entry before you start clightning again. A network dir
(`bitcoin` on mainnet) that a group member created can hold an `hsm_secret` that the
member controls.
