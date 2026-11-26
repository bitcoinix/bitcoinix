# RTL

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

RTL listens on localhost by default. Connect to it through an SSH tunnel, then open
`http://localhost:3000` in your browser:

```
ssh -L 3000:127.0.0.1:3000 operator@bitcoin-node
```

With `netns-isolation`, RTL listens in its own network namespace. Use the address from
`nodeinfo | jq -r .rtl.local_address` instead, e.g. `169.254.1.29:3000`.

RTL's web interface is plain HTTP. A local user who takes RTL's port could show you a
fake login page and collect the password. So without `netns-isolation`, RTL listens on
a unix socket, and systemd holds `services.rtl.address` and `port` with a socket unit,
`rtl-proxy-*.socket`, also while RTL is stopped. The address must then be a numeric IP
address without a zone ID. With a host name, a zone ID or a socket path, the system
build fails. A switch that changes the address or port frees the port for a moment.
In the tunnel, use the address and port that systemd holds.
By default that's `127.0.0.1:3000`, as above. If you set another address or port, use
those, with `127.0.0.1` for `0.0.0.0` and `[::1]` for `::`. With `localhost`, sshd may
connect to `[::1]:3000`, which systemd doesn't hold with the default address.
With `netns-isolation`, RTL's address exists only in RTL's namespace, and no process in
the host namespace can take it.

With the `secure-node.nix` or `enable-tor.nix` preset, RTL also has an onion service.
Open `http://<onion address>` in Tor Browser, using the address from
`nodeinfo | jq -r .rtl.onion_address`.

The password is in `$secretsDir/rtl-password`.
See: [Secrets dir](../configuration.md#secrets-dir)

## Backend maintenance

RTL is bound to the units of its backends. It stops when the lnd or clightning unit
stops, crashes or exits, and the backend's next start starts it again. With both
backends enabled, stopping one of them also stops RTL for the other one, and
starting RTL starts a stopped backend too. So during maintenance of one backend,
leave RTL stopped.

## Backend credentials

RTL gets its own lnd macaroon and clightning rune. With them, RTL can send funds and
open and close channels, but it can't bake macaroons, create runes, stop lnd, delete
lnd's payment history or use lnd's signer RPCs. RTL copies them to its data dir when
it starts.

- lnd: the custom macaroon `services.lnd.macaroons.rtl`, see
  [Custom macaroons](lnd.md#custom-macaroons). It allows only the lnd RPCs that RTL calls.
  Its permissions for the RPCs of `invoicesrpc` and `walletrpc` are optional, so RTL
  also starts with an lnd package that lacks their build tags. RTL's features that use
  these RPCs then fail.
- clightning: a rune that allows only the methods that RTL calls. bitcoinix creates it
  once and keeps it at `rtl-rune` in clightning's network dir. The rune has the comment
  `bitcoinix-rtl`. Each start of RTL revokes all other runes with this comment, for
  example the old rune after an update that changes RTL's methods.

  To revoke the rune, for example after a leak, run
  `lightning-cli blacklistrune <id> <id>` with the `unique_id` that
  `lightning-cli showrunes` shows for it. Then run `systemctl restart clightning`.
  clnrest runs as a plugin of clightning, and it checks the rune of a websocket client
  only when the client connects. So the restart closes the connections that still use
  the revoked rune. clightning's start also starts RTL again, see
  [Backend maintenance](#backend-maintenance), and RTL creates a new rune. A new rune
  gets the next unique ID, also when that ID is blacklisted. So RTL's start creates up
  to 10 runes until one has an ID that isn't blacklisted. If there's none, the start
  fails. systemd starts RTL again after 10 seconds, and it tries the next IDs. Each
  failed try stores 10 more runes in clightning's database, so blacklist only the IDs of
  runes that you have.

  When you disable RTL or its clightning node in your config, the rune stays valid.
  Revoke it the same way. Then the restart doesn't start RTL. If nothing else in your
  config enables clightning, the deploy also removes clightning and `lightning-cli`.
  Then you can't revoke the rune, and it works again when you enable clightning later.
  So revoke the rune before the deploy. Run `systemctl stop rtl`, blacklist the rune while clightning
  still runs, and then deploy. The deploy stops clightning, which closes clnrest's
  connections. A start of lnd or clightning before the deploy starts RTL again, and
  RTL creates a new rune. So right before the deploy, check that `systemctl is-active rtl`
  prints `inactive` and that `lightning-cli showrunes` shows each rune with the comment
  `bitcoinix-rtl` as blacklisted.

  clightning keeps the revoked runes and the count of unique IDs in its database.
  When clightning starts with a new or older database, for example after a recovery,
  revoked runes work again, and a new rune can get the unique ID of an older rune,
  like the admin rune. Revoking one of them then revokes both.

## Backend certificates

A connection from RTL to a backend's address and port must present that backend's
pinned certificate: `services.lnd.certPath` for lnd, or `server.pem` in clnrest's cert
dir (clightning's network dir, or `clnrest-certs`). So a local process that takes a
backend's port gets neither the lnd macaroon nor the clightning rune. Every other HTTPS
connection gets the normal certificate and hostname checks against the system CAs.
RTL doesn't start when `LN_SERVER_URL` or `LND_SERVER_URL` is set in its environment.
To use another server with a self-signed certificate, for example a swap server set
through `extraConfig`, add its certificate to RTL's environment with
`systemd.services.rtl.environment.NODE_EXTRA_CA_CERTS`.

## Reset two-factor authentication

Two-factor authentication that you set up in RTL stays on across restarts. If you
lose the authenticator, delete `RTL-Config.json` in RTL's data dir
(`/var/lib/rtl` by default) and restart RTL. bitcoinix then writes a new one
without the 2FA secret.
