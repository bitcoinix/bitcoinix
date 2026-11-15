# Release notes

For configuration migrations reported during evaluation, follow the
[upgrading guide](upgrading.md).

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
