## Examples

The easiest way to try out bitcoinix is to use one of the provided examples.

### Flakes-based quick start

If you use a Flakes-enabled version of Nix, run the following command to start a minimal
bitcoinix QEMU VM:
```bash
nix run github:bitcoinix/bitcoinix/v<version>
```
Replace `<version>` with the latest release tag listed at
<https://github.com/bitcoinix/bitcoinix/tags>.\
The VM (defined in [flake.nix](../flake.nix)) runs in the terminal and has `bitcoind`
and `clightning` installed.\
It leaves no traces (outside of `/nix/store`) on the host system.


### More examples

Clone this repo and enter the examples shell:
```bash
git clone https://github.com/bitcoinix/bitcoinix
cd bitcoinix/examples/
nix-shell
```

The following example scripts set up a bitcoinix node according to [`./configuration.nix`](configuration.nix) and then
shut down immediately. They leave no traces (outside of `/nix/store`) on the host system.\
By default, [`./configuration.nix`](configuration.nix) enables `bitcoind` and `clightning`.

- [`./deploy-container.sh`](deploy-container.sh) creates a [NixOS container](https://github.com/extra-container/extra-container).\
  This is the fastest way to set up a node.\
  Requires: [Nix](https://nixos.org/), a systemd-based Linux distro and root privileges

- [`./deploy-qemu-vm.sh`](deploy-qemu-vm.sh) creates a QEMU VM.\
  Requires: [Nix](https://nixos.org/nix/), Linux

- [`./deploy-krops.sh`](deploy-krops.sh) creates a QEMU VM and deploys a
  bitcoinix configuration to it using [krops](https://github.com/krebs/krops).\
  Requires: [Nix](https://nixos.org/nix/), Linux

- [`./deploy-container-minimal.sh`](deploy-container-minimal.sh) creates a
  container defined by [importable-configuration.nix](importable-configuration.nix).\
  You can copy and import this file to use bitcoinix in an existing NixOS configuration.\
  The configuration doesn't use the [secure-node.nix](../modules/presets/secure-node.nix) preset.\
  Requires: [Nix](https://nixos.org/), a systemd-based Linux distro and root privileges

Run the examples with option `--interactive` or `-i` to start a shell for interacting with
the node:
```bash
./deploy-qemu-vm.sh -i
```

### Tests
The [bitcoinix test suite](../test/README.md) is also useful for exploring features.

### Deployment examples

See [bitcoinix-examples](https://github.com/bitcoinix/bitcoinix-examples) for
additional deployment configurations, including Colmena.

### Flakes

Flakes make it easy to include `bitcoinix` in an existing NixOS config.
The [flakes example](./flakes/flake.nix) shows how to use `nix-bitcoin` as an input to a system flake.

### Persistent container with Flakes

The [persistent container](./container) example shows how to run a Flake-based node
in a container.\
Requires: A systemd-based Linux distro and root privileges.

### Extending bitcoinix with Flakes

The historical [mempool extension flake](https://github.com/fort-nix/nix-bitcoin-mempool)
illustrates how to define packages and modules in a flake for the predecessor project.
Mempool is included in bitcoinix itself; enable it with `services.mempool.enable`.
