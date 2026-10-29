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

* 1 TB for an unpruned
  instance of Bitcoin Core.
  * This can be significantly lowered by enabling pruning.
    Note: Pruning is not supported by electrs and Fulcrum.
