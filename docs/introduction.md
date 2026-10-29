<img src="img/logo-text.svg" width="320" alt="bitcoinix">

# Introduction

**bitcoinix** is a collection of Nix packages and NixOS modules for deploying full-featured
Bitcoin and Lightning nodes with an emphasis on security.

Use it for personal or merchant wallets, public infrastructure or Bitcoin application backends,
on dedicated hardware, in a virtual machine or in a container. You don't need previous
experience with Nix. bitcoinix is used in production, but it is still considered experimental.

bitcoinix is a community fork of [nix-bitcoin](https://github.com/fort-nix/nix-bitcoin), which
was archived in August 2026. The NixOS options keep the `nix-bitcoin.*` prefix, so existing
configurations keep working.

## Features

* Bitcoin Core, with Core Lightning or LND
* Electrum servers (electrs, Fulcrum), the mempool explorer, BTCPay Server and the RTL web interface
* Mobile wallet connections, e.g. ZEUS via [Tor](services.md#use-zeus-mobile-lightning-wallet-via-tor)
  or [WireGuard](services.md#use-zeus-mobile-lightning-wallet-via-wireguard)
* Helpers: [nodeinfo](services.md#nodeinfo), backups, and a non-root `operator` user for the
  client tools

The [README](https://github.com/bitcoinix/bitcoinix#features) lists all services and plugins, the
[NixOS options search](https://search.nixos.org/flakes?channel=unstable&sort=relevance&type=options&query=bitcoin)
lists their options.

## Security

* Only the services you enable and their dependencies are installed.
* Each service runs as its own user and is confined with systemd sandboxing. Network namespace
  isolation (`nix-bitcoin.netns-isolation`) can further restrict which services can reach each other.
* The `secure-node.nix` preset sends outgoing connections through Tor, adds onion services for
  incoming connections, enables the firewall and replaces sudo with doas.
* Release tags are signed by the maintainers. `fetch-release` and `update-nix-bitcoin` in the
  deployment shell verify the signature before they use a release.

## Where to start

1. [Hardware requirements](hardware.md): choose a machine for your node.
2. [Installation](install.md): set up a new node from scratch. To add bitcoinix to an existing
   NixOS configuration, start from the [examples](https://github.com/bitcoinix/bitcoinix/tree/master/examples).
3. [Configuration and maintenance](configuration.md): customize services and allow external connections.
4. [Using services](services.md): connect wallets and manage the services.
5. [Upgrading](upgrading.md): read this before you update bitcoinix.
6. [FAQ](faq.md)

Some pages still come from nix-bitcoin and are being reviewed. If something is wrong or doesn't
work, please [open an issue](https://github.com/bitcoinix/bitcoinix/issues).
