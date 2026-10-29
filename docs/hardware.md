Hardware requirements
---

> [!NOTE]
> This document is inherited from nix-bitcoin, the predecessor project. It is a work in progress and may be outdated.

## Platforms

bitcoinix supports two platforms:

- `x86_64-linux`: 64-bit Intel and AMD CPUs
- `aarch64-linux`: 64-bit ARM CPUs

Other platforms are not supported.

## Memory

* RAM: 2 GB. ECC memory is better. Additionally, it's recommended to use DDR4 memory with
  targeted row refresh (TRR) enabled (https://rambleed.com/).

## Disk space

Use a disk of at least 2 TB, preferably an SSD. An Electrum server (electrs or Fulcrum)
needs an unpruned Bitcoin Core node and adds its own index on top of it.

### Pruning

[`services.bitcoind.prune`](https://github.com/bitcoinix/bitcoinix/blob/master/modules/bitcoind.nix)
limits the block files to a target size in MiB and lowers the disk usage. The smallest
target that Bitcoin Core accepts is 550.

Not every service works on a pruned node:

- electrs and Fulcrum don't support pruning, and evaluation fails.
- mempool enables `services.bitcoind.txindex`, and Bitcoin Core doesn't start with both
  pruning and the transaction index.
- Core Lightning works. Its `bcli` plugin fetches pruned blocks from peers.
