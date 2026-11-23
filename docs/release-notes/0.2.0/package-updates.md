#### Package updates

- CLBOSS 0.17.2 → [0.17.3](https://github.com/ksedgwic/clboss/releases/tag/v0.17.3).
  It pays a swap invoice only when it matches the swap that it requested. A swap
  started by one version can't be claimed by the other: it ends at its timeout and
  the payment fails back to the node. Finish active swaps before you update or roll
  back. On mainnet, CLBOSS makes no swaps, because its swap provider suspended
  them on 2026-08-03.
- electrs 0.12.0 → [0.12.1](https://github.com/romanz/electrs/releases/tag/v0.12.1)
- charge-lnd 0.3.1 → 0.3.2
- HWI 3.1.0 → [3.2.0](https://github.com/bitcoin-core/HWI/releases/tag/3.2.0)
- extra-container 0.17 → 1.0.1 in the deployment shell. Containers that you build
  with its `extra-container` command no longer reach the host's Nix daemon, see
  [extra-container 1.0.1](../0.1.6.md#extra-container-101).
- nginx 1.30.6 → 1.30.7, which fixes nine CVEs, see the
  [nginx changelog](https://nginx.org/en/CHANGES-1.30). A default node isn't exposed:
  nginx serves only the mempool frontend, over plain HTTP on a local address, without
  `alias`. Check your own nginx configuration against the list.
