# LND

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

## Custom macaroons

`services.lnd.macaroons.<name>` gives a service its own macaroon with only the
permissions it needs. Each time lnd starts, bitcoinix creates the macaroon at
`/run/lnd/<name>.macaroon`, readable only by `user`. BTCPay Server, charge-lnd, RTL and
Unbeholden LNURL on lnd get their macaroons this way.

```nix
services.lnd.macaroons.myapp = {
  user = "myapp";
  permissions = ''{"entity":"info","action":"read"},{"entity":"invoices","action":"write"}'';
};
```

A `uri` permission, like `{"entity":"uri","action":"/lnrpc.Lightning/GetInfo"}`,
allows one RPC. When lnd doesn't have the RPC of a `uri` permission in `permissions`,
for example because its name has a typo, lnd's start fails. Some RPCs, like those of
`walletrpc`, exist only when lnd's package has their build tag. Put the `uri`
permissions for these RPCs in `optionalPermissions`, in the same format. When lnd
doesn't have one of these RPCs, the macaroon doesn't get its permission, and lnd's
start logs a warning.

### Root keys and configuration changes

Each custom macaroon has its own lnd root key. Its ID,
`services.lnd.macaroons.<name>.rootKeyId`, is derived from the name, user,
permissions and optional permissions, so copies of the macaroon stay valid when lnd
restarts. A change of one of them gives the macaroon a new ID. Each time lnd starts,
bitcoinix deletes the root key of every ID from 7953919891889717248 to
7954201366866427903 (`0x6e62000000000000` to `0x6e62ffffffffffff`) that no
configured macaroon uses. If it deleted a root key, it restarts lnd once more,
which closes the connections that use these macaroons. If this restart fails
while the old lnd process still runs, it stops lnd. So when you change or
remove a macaroon, its copies stop working when lnd restarts during the
deployment. Until then, a leaked copy keeps working. Copies created before
bitcoinix 0.1.6 are an exception: they use root key 0 and stay valid until you
[revoke all macaroons](#revoke-all-macaroons). Don't use IDs in this range for
macaroons that you bake yourself.

bitcoinix creates the macaroons and deletes the stale root keys with `lncli`,
lnd's admin macaroon and gRPC. It does this each time lnd starts, also without
custom macaroons, so lnd must keep its macaroons enabled: the `no-macaroons`
option isn't supported.

### Restart services after macaroon changes

A service that reads its macaroon only at startup must restart to read the new
macaroon. Restart it on deployments that change the macaroon:

```nix
systemd.services.myapp.restartTriggers = [ config.services.lnd.macaroons.myapp.rootKeyId ];
```

A change of lnd's package can add or remove optional permissions without a new ID. So
if the macaroon has optional permissions, also add `config.services.lnd.package` to
the triggers.

BTCPay Server reads its macaroon for each request to lnd, and charge-lnd for each
run. RTL copies its macaroon when it starts, and it restarts with lnd.

### Revoke a macaroon

To revoke all copies of a macaroon without changing its configuration:

1. Find the root key ID of the macaroon in lnd's log:
   ```
   journalctl -b -u lnd --grep 'Create custom macaroon myapp'
   ```
   `lncli listmacaroonids` lists all root key IDs.
2. Delete the root key: `lncli deletemacaroonid <ID>`
3. Restart lnd: `systemctl restart lnd`. This closes the connections that use the
   macaroon. lnd creates a new root key with the same ID, and bitcoinix creates a new
   `/run/lnd/myapp.macaroon`.
4. Restart the service that uses the macaroon.

### Revoke all macaroons

lnd's default macaroons, like `admin.macaroon`, share root key 0, and so do
custom macaroons created before bitcoinix 0.1.6. lnd can't delete root key 0. To revoke
these macaroons, replace all root keys. `lncli changepassword --new_mac_root_key`
doesn't work on bitcoinix, because lnd unlocks the wallet when it starts. Instead,
delete the macaroon database and the macaroon files in the lnd network dir
(`services.lnd.networkDir`) while lnd is stopped. This works with lnd's default
database backend (bbolt). With another `db.backend` in `services.lnd.extraConfig`,
the root keys are in that database instead. Run as root:

1. Keep a copy of the current admin macaroon, to check at the end that old
   macaroons stop working:
   ```
   runuser -u lnd -- cp /var/lib/lnd/chain/bitcoin/mainnet/admin.macaroon /var/lib/lnd/old-admin.macaroon
   ```
   Then stop lnd and the units that can start it, so that none starts lnd during the
   next step: `charge-lnd.timer` and the services that require or want lnd.
   `systemctl list-dependencies --reverse lnd.service` lists them. For example,
   with charge-lnd, BTCPay Server and RTL (leave out the ones your node doesn't have):
   ```
   systemctl stop charge-lnd.timer charge-lnd btcpayserver rtl lnd
   ```
2. Delete the files as the lnd user, here for the default mainnet dir:
   ```
   runuser -u lnd -- sh -c 'cd /var/lib/lnd/chain/bitcoin/mainnet && rm -f macaroons.db *.macaroon'
   ```
3. Restart lnd, so that a fresh process opens the new database. Check that the new
   admin macaroon works and the old copy doesn't:
   ```
   systemctl restart lnd
   lncli --profile= getinfo
   lncli --profile= --macaroonpath /var/lib/lnd/old-admin.macaroon getinfo
   ```
   `--profile=` makes lncli ignore a saved default profile. The first `getinfo` must
   work and the second must fail with an authentication error. If not, a unit
   (bitcoind too) started lnd during step 2. Run the `stop` command from step 1
   again, then steps 2 and 3, and keep the old copy.
   Then delete the copy: `runuser -u lnd -- rm /var/lib/lnd/old-admin.macaroon`.
4. Start the units that you stopped, for example
   `systemctl start charge-lnd.timer btcpayserver rtl`. RTL copies its macaroon
   when it starts.

lnd creates new root keys and new default macaroons, and bitcoinix creates new
custom macaroons. All earlier macaroons stop working. Then:

- Create new connection URLs with `lndconnect` or `lndconnect-wg` and connect your
  wallets again.
- Bake new macaroons for the macaroons that you baked yourself.
