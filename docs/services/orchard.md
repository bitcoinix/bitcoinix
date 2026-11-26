# Orchard

[Orchard](https://orchard.space) provides a web dashboard for the local
[CDK Cashu mint](cdk-mint.md): balances, quotes, proofs, keysets and mint management.

```nix
services.orchard.enable = true;
```

This also enables `services.cdk-mintd` and its selected Lightning backend. Configure
the mint through `services.cdk-mintd`; for example, set `backend = "clightning";`
to use Core Lightning instead of LND. Orchard's Bitcoin, Lightning, Taproot Assets
and Prometheus panels are not configured by this module.

## Access and initial setup

The web interface listens on `127.0.0.1:3321` by default. For an SSH tunnel:

```bash
ssh -L 3321:127.0.0.1:3321 operator@node
```

Open `http://localhost:3321`. With network namespace isolation, use the Orchard
address from `nodeinfo` as the tunnel destination instead of `127.0.0.1`.
Alternatively, enable its onion service:

```nix
nix-bitcoin.onionServices.orchard.enable = true;
```

Use `nodeinfo` to find the onion address and open it in Tor Browser. The onion
service exposes port 80. For a public domain, put an HTTPS reverse proxy in front
of Orchard; the module does not open firewall ports.

Retrieve the setup key on the node (adjust `/secrets` if using another
`nix-bitcoin.secretsDir`):

```bash
sudo cat /secrets/orchard-setup-key
```

Use this key to create the first administrator account, choosing your own username
and password. The setup key is not the login password. It is generated when
`nix-bitcoin.generateSecrets` is enabled; `services.orchard.setupKeyFile`
can instead point to an existing secret. Subsequent logins use the account you
created. Restarting Orchard invalidates login sessions.

## Permissions and configuration

Orchard runs as a separate user. It can read the mint SQLite database and its
WAL files, but cannot write them or read the mint seed, BDK wallet or Lightning
credentials. Management operations use CDK's gRPC API with mutual TLS. The RPC
listener stays on loopback, or the mint's private namespace address, independently
of the public mint HTTP listener. Its default port is 8086; change
`services.orchard.mintRpcPort` if needed.

Treat Orchard administrator access as mint administration access: it allows
metadata and fee changes and keyset rotation. Overriding quote payment state is
disabled. Changes made through Orchard can be replaced when a changed Nix mint
configuration is applied. Keep intended persistent settings in
`services.cdk-mintd.settings`.

Without automatic secret generation, supply `orchard-setup-key` (unless
using a custom file) and these TLS files through your [secrets setup](../configuration.md):

- `orchard-rpc-ca-key` and `orchard-rpc-ca-cert`;
- `orchard-rpc-server-key` and `orchard-rpc-server-cert`;
- `orchard-rpc-client-key` and `orchard-rpc-client-cert`.

Use PEM files with separate server and client keys, signed by the CA. The server
certificate needs the RPC IP address as a subject alternative name and the
`serverAuth` extended key usage; the client certificate needs `clientAuth`.
The CA key is root-only; each service receives only its own private key.

## State and recovery

Orchard stores accounts, settings and `crypto.key` in
`services.orchard.dataDir` (default `/var/lib/orchard`). Back up this
whole directory while `orchard.service` is stopped, together with its
secrets. Restore the directory with the configured Orchard user/group and mode
`0700`. Orchard state is not automatically included in `services.backups`.

Use the [CDK backup and recovery procedure](cdk-mint.md#automated-backups) for
mint state. Orchard's database download does not include the signing secrets or
initialization guard, and its database restore cannot write the protected mint
database. Orchard stops with the mint during its backups and restarts when the
mint starts again.

For startup or connection failures, check `journalctl -u orchard -u cdk-mintd`.
See the [options](../options.md) for paths, listeners and package overrides.
