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
