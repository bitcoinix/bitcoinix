# Release notes

For configuration migrations reported during evaluation, follow the
[upgrading guide](upgrading.md).

## 0.2.0

#### Migration warnings on master

Unreleased configuration migrations now warn without blocking deployment or
requiring acknowledgement. Users following master must review them before
deploying; warnings cannot be acknowledged individually and repeat while
applicable. A `configVersion` newer than the latest finalized release is rejected.
Finalizing the release makes its notices blocking errors until acknowledged. See
the [upgrading guide](upgrading.md) for the version policy.

#### Unstable NixOS base

bitcoinix now uses a single `nixpkgs` input tracking `nixos-unstable` for its system
and packages. `nix-bitcoin.useVersionLockedPkgs` defaults to `true`. Review the
[0.2.0 migration guide](upgrading.md#upgrading-to-config-version-020) for the system
input, package customization, reverse-path filtering, FUSE, I2P validation and
systemd-nspawn changes. Non-flake module imports, disabling version-locked
packages, or overriding bitcoinix's nixpkgs input now also move the formerly
separately pinned unstable service packages with the caller's nixpkgs.

#### TrustedCoin initialization

The pinned TrustedCoin package applies two patches from the
[upstream startup fix](https://github.com/nbd-wtf/trustedcoin/pull/44) to prevent
initialization races and reporting height zero without a block source.

#### Electrs uses the unmodified nixpkgs package

Nixpkgs now supplies electrs' pkg-config and zstd build inputs, so the local
override is no longer needed.

#### Package selection cleanup

The generated `pkgs/pinned.nix` file has been removed. Package selection and
local overrides now live together in `pkgs/default.nix`; the public
`legacyPackages.<system>.pinned` paths remain available. The deployment shell and
package imports without an explicit `pkgs` still read the lock file through
`pkgs/nixpkgs-pinned.nix`; non-flake NixOS module imports use the system's `pkgs`.

#### Bitcoin network selection

Select the Bitcoin network with `services.bitcoind.network` (`"mainnet"` or
`"regtest"`) instead of `services.bitcoind.regtest`. The `makeNetworkName` helper
is replaced by `nix-bitcoin.lib.networkName`, which accepts name overrides and
passes other network names through unchanged. See the
[0.2.0 upgrade notes](upgrading.md#upgrading-to-config-version-020).

#### Mempool regtest support

Mempool's backend and frontend now follow `services.bitcoind.network`, including
regtest. See the [0.2.0 upgrade notes](upgrading.md#upgrading-to-config-version-020)
for existing regtest deployments and custom frontend settings.

#### Charge-LND credential paths

Charge-LND reads its certificate and macaroon directly, without staging them
under a synthetic mainnet directory. Users selecting custom credentials with
`--lnddir` should follow the [0.2.0 upgrade notes](upgrading.md#upgrading-to-config-version-020).

#### lnconnect-clnrest finds clnrest's certificate in a custom dir

`lnconnect-clnrest` now asks clightning for clnrest's cert dir, like RTL does. Before,
it always read `server.pem` from clightning's network dir. So with `clnrest-certs` set,
it failed or put the wrong certificate into direct connection URLs. Regenerate such URLs.
When clightning doesn't answer, for example because it's stopped, `lnconnect-clnrest`
prints a warning and uses the network dir, as before.

#### Backup password and migrated lnd seed

With `nix-bitcoin.generateSecrets`, the backups include the password that decrypts them,
`backup-encryption-password` in the secrets dir. Keep a copy of it off the node. If you
migrated lnd from another node, the `lnd-seed-mnemonic` on the node may not hold the
seed of your wallet. See
[Migrate existing services to bitcoinix](configuration.md#migrate-existing-services-to-bitcoinix).

#### The secure-node preset turns off SSH password login

The `secure-node.nix` preset now turns off SSH password and keyboard-interactive login
by default, so its sshd onion service accepts only keys. See
[Upgrading to config version 0.2.0](upgrading.md#upgrading-to-config-version-020).

#### NBXplorer RPC password permissions

BTCPay Server can no longer read NBXplorer's bitcoind RPC password. Only NBXplorer's
user can read it now. Before, BTCPay Server could read it through the group that
gives it NBXplorer's API cookie. See
[Upgrading to config version 0.2.0](upgrading.md#upgrading-to-config-version-020).

#### BTCPay Server's access to the Lightning node

With `services.btcpayserver.lightningBackend = "clightning"`, BTCPay Server has full
control of the Lightning node, including its funds. With `lnd`, it gets a restricted
macaroon. See [Lightning backend](services.md#lightning-backend).

#### Custom RPC users' password HMACs are in the Nix store

The `passwordHMAC` of each custom RPC user in `services.bitcoind.rpc.users` is
written to the world-readable Nix store. Any local user can read it and test password
guesses offline. This isn't new, but it wasn't documented. If a custom RPC user has a
weak password, replace it with a long random one. See
[Allow bitcoind RPC connections from LAN](configuration.md#allow-bitcoind-rpc-connections-from-lan).

## 0.1.6

#### Tor enforcement allows only local addresses

Services with `tor.enforce` and charge-lnd could reach every link-local address
`169.254.0.0/16`, including a cloud provider's metadata service, and could resolve
names through the host's resolver sockets, outside the Tor-only restriction. They
now reach only localhost and, with netns-isolation, the namespace subnet, and can't
use the nscd, systemd-resolved, D-Bus and Avahi sockets. netns-isolation rejects
`addressblock` 169 and 170. Setups that connect such a service to a non-local
address or by host name need a change, see the
[upgrade notes](upgrading.md#tor-enforcement-allows-only-local-addresses).

#### Unbeholden Wallet service

New service: [Unbeholden Wallet](services.md#connect-to-unbeholden-wallet), a watch-only
wallet that runs in the browser and hands transactions to an air-gapped signer over QR
codes. Enable it with `services.unbeholden-wallet.enable = true;`. It connects to electrs,
or to Fulcrum with `services.unbeholden-wallet.electrumServer = "fulcrum"`.

#### RTL package moves to nixpkgs

RTL now uses the nixpkgs package. Replace explicit flake references to
`packages.<system>.rtl` or `legacyPackages.<system>.rtl` with
`legacyPackages.<system>.pinned.rtl`. For example, build it with
`nix build '.#legacyPackages.aarch64-linux.pinned.rtl'` (or `x86_64-linux`).
The service still uses `nix-bitcoin.pkgs.rtl` automatically.

#### TrustedCoin package moves to nixpkgs

TrustedCoin now uses the nixpkgs package. Replace explicit flake references to
`packages.<system>.trustedcoin` or `legacyPackages.<system>.trustedcoin` with
`legacyPackages.<system>.pinned.trustedcoin`. For example, build it with
`nix build '.#legacyPackages.aarch64-linux.pinned.trustedcoin'` (or `x86_64-linux`).
The plugin still uses `nix-bitcoin.pkgs.trustedcoin` automatically.

#### Trezor uses the unmodified nixpkgs-unstable package

Trezor now uses the unmodified nixpkgs-unstable package. Replace explicit package
references to `nix-bitcoin.pkgs.pyPkgs.nbPython3PackagesWithUnlockedEcdsa.trezor`
with `nix-bitcoin.pkgs.nbPython3Packages.trezor`. The
`services.hardware-wallets.trezor` option selects it automatically; `trezorctl`
remains available. HWI retains its separate ECDSA exception.

#### Lightning Python packages move to nixpkgs-unstable

`nbPython3Packages` now uses nixpkgs-unstable's Python interpreter and package set,
including `pyln-bolt7`, `pyln-client`, `pyln-proto` and `pylightning`. Their versions
are selected by nixpkgs-unstable independently of the Core Lightning daemon.
In custom configurations, build Python environments with the matching interpreter,
for example:

```nix
config.nix-bitcoin.pkgs.nbPython3Packages.python.withPackages (ps: [ ps.pyln-client ])
```

The built-in Python plugins select this interpreter automatically. The package
paths under `nbPython3Packages` remain available.

#### Secret validation and lnd wallet creation

`setup-secrets` now fails when a declared secret file is empty or isn't a regular
file. Set `nix-bitcoin.secrets.<name>.allowEmpty = true` for a secret that may be
empty. Secret generation now fails when a TLS, WireGuard or replication SSH private
key is empty, and it doesn't replace the key. lnd now stops when `wallet.db` isn't a
regular file, for example a symlink to a missing file. While lnd has no wallet yet,
it also stops when its seed file is a symlink to a missing file, and its error for an
empty seed file names the file. lnd now creates its seed and wallet through temporary
files, so a failed wallet creation no longer leaves a partial `wallet.db` that
blocks later starts.

#### Separate root keys for custom lnd macaroons

Each custom lnd macaroon (`services.lnd.macaroons`, used by BTCPay Server and
charge-lnd) now has its own root key. You can revoke one of them, and the other
macaroons and lnd's admin macaroon stay valid. The revocation needs an lnd restart.
When you change or remove a macaroon, its old copies stop working when lnd restarts
during the deployment. Copies made before 0.1.6 use root key 0 and stay valid until
you revoke all macaroons. See [Custom macaroons](services.md#custom-macaroons).

#### Custom lnd macaroon file permissions

A custom lnd macaroon is now readable only by its `user`. Before, the user's primary
group could read it too. For a user like `operator`, that's the group `users`, which
normal users get by default. So other normal users could read the macaroon.

#### RTL stops with its backends

RTL now stops when lnd or clightning stops, crashes or exits. Before, it kept sending
their admin credentials to the port of a stopped backend. A backend's start starts RTL
again, and with both backends enabled, both must run.

#### RTL verifies its backends' certificates

RTL now checks TLS certificates. Before, it sent the lnd admin macaroon and the
clightning admin rune to any server on a backend's port. RTL has no option for this,
so bitcoinix loads a small Node module into RTL. A connection to a backend must present
the backend's pinned certificate: `services.lnd.certPath` for lnd, or clnrest's
`server.pem`. Other HTTPS connections get the normal checks against the system CAs.
See [Upgrading to config version 0.1.6](upgrading.md#upgrading-to-config-version-016)
for what no longer works.

#### RTL two-factor authentication persists across restarts

Two-factor authentication set up in the RTL web interface now survives restarts.
Each start still resets the other web interface settings in `RTL-Config.json` to
the Nix configuration. `RTL-Config.json` is now readable only by RTL's user. To
turn 2FA off without the authenticator, see
[Connect to RTL](services.md#connect-to-rtl).

#### Onion address access for the operator and declared users

`services.lnd.lndconnect.onion` and `services.clightning.plugins.clnrest.lnconnect.onion`
now give the operator user access to the `lnd-rest` and `clnrest` onion addresses only
when `nix-bitcoin.operator.enable` is set. Before, a missing operator user made the
`onion-addresses` service fail, and no onion address was published.
`nix-bitcoin.onionAddresses.access` now accepts only users that are defined and enabled
in `users.users`. See the upgrade notes on
[operator access](upgrading.md#operator-access-to-lightning-onion-addresses) and
[declared users](upgrading.md#onion-address-access-requires-declared-users).

#### Backups fail when a database dump fails

With `services.backups`, a failed PostgreSQL dump now fails the `duplicity` unit. Before,
the backup succeeded without the database. The other files are still backed up in that
run. The backup now also includes the BTCPay Server and NBXplorer dumps when
`services.postgresqlBackup.compression` is `zstd` or `none`. Before, it silently left
them out with these settings, so take a new backup if you use one of them.
`systemctl start duplicity` now blocks until the backup finishes.

#### netns-isolation: no masquerading within the bridge, MPTCP setting

With `br_netfilter` loaded, which Docker does, a netns-isolated service without
`tor.enforce` could reach the listeners of namespaces it isn't connected to. Traffic
between namespaces is no longer masqueraded, which closes this. The service namespaces
now also copy the host's `net.mptcp.enabled` when they are created, so the MPTCP setting
of `presets/hardened-extended.nix` reaches netns-isolated services. Upgrading restarts
every netns-isolated service once.

#### Root scripts ignore config files in a service user's home

Service scripts that run as root no longer load configuration files from the service
user's home directory. Before, the lnd user could make root's `curl` and `jq` load
`~/.curlrc` and `~/.jq` from lnd's data directory.

#### WireGuard preset checks the firewall setup

`presets/wireguard.nix` now fails evaluation for firewall setups in which its rules
can't run or don't stay loaded: the nftables firewall package without iptables,
`networking.nftables.flushRuleset`, and an `ip` or `ip6` table named `filter` in
`networking.nftables.tables`. The messages say what to change.

#### lnd announces its onion address with the port Tor forwards

With a public lnd onion service and a `services.lnd.port` other than 9735, lnd announced
`<onion>:9735`, and peers couldn't reach the node over Tor. It now announces the port
that Tor forwards.

#### clnrest regenerates a broken admin rune

A failed `createrune` on clightning's first start could install an empty or `null`
clnrest admin rune that later starts kept. Such a rune is now replaced on start, and a
failed `createrune` fails the start. Generate connection URLs from `lnconnect-clnrest`
again if they were created with a broken rune.

#### btcpayserver with a custom clightning group

With `lightningBackend = "clightning"`, the btcpayserver user now joins
`services.clightning.group`. Before, it joined a group named after
`services.clightning.user` and couldn't open the RPC socket when the two differed.

#### nodeinfo shows the bitcoinix revision and service versions

`nodeinfo` now prints the bitcoinix commit in a `bitcoinix` entry and the package version
of each service. `nodeinfo --version` prints only the revision, and `nodeinfo NAME ...`
only the given entries. Because the revision is part of the script, every bitcoinix
update now produces a new system generation. Set `nix-bitcoin.revision = null;` to opt
out. See [nodeinfo](services.md#nodeinfo).

#### extra-container 1.0.1

The flake's `extra-container` input moves from 0.17 to
[1.0.1](https://github.com/extra-container/extra-container/releases/tag/v1.0.1). This
release has a breaking change: containers can no longer reach the host's Nix daemon
socket by default, so `nix build`, `nix run`, `nix develop` and `nix-shell` fail inside
a container. This affects containers built with this input, for example with
`examples/container`. `extra.hostNixDaemon = true;` restores the old behavior. Read the
security section of the extra-container README first.

#### Package updates

- lnd 0.21.6-beta → 0.21.8-beta
  ([release notes](https://github.com/lightningnetwork/lnd/blob/master/docs/release-notes/release-notes-0.21.8.md)).
  A bug-fix release without database migrations. lnd now rejects a new channel that
  negotiates a CSV delay of zero.
- RTL 0.15.16 → 0.15.17
  ([release notes](https://github.com/Ride-The-Lightning/RTL/releases/tag/v0.15.17)).
  Fixes login problems and accepts 2FA codes when the server clock is slightly off.

See also [Upgrading to config version 0.1.6](upgrading.md#upgrading-to-config-version-016).

## 0.1.5

#### clnrest package attribute renamed

The clnrest package has moved from `nix-bitcoin.pkgs.clnrest` to
`nix-bitcoin.pkgs.clightning-plugins.clnrest`. Update explicit package references
in custom configurations and scripts. For flake builds, use
`'.#packages.aarch64-linux.clightning-plugins/clnrest'` (or `x86_64-linux`)
instead of `'.#packages.aarch64-linux.clnrest'`.
The default package is selected automatically, including when RTL enables clnrest.
If you have no custom package references, this rename requires no manual changes.

For this release's configuration and service migrations, see
[Upgrading to config version 0.1.5](upgrading.md#upgrading-to-config-version-015).
