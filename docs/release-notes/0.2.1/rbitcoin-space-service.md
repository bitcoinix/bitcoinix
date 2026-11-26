#### rbitcoin.space service (experimental)

New service: [rbitcoin.space](../../services.md#rbitcoinspace) 0.5.0, a block explorer for
rbitcoin with a live mempool, projected blocks, mining pages and an Esplora-compatible
API.

- Turn it on with `services.rbitcoin-space.enable = true;`.
- It requires rbitcoin as its backend and enables [rbitcoin](../../services.md#rbitcoin) for
  you, with its RPC, Electrum and Esplora servers. It doesn't run on bitcoind or electrs.
- It is separate from mempool and works with any `services.mempool.electrumServer`.
- `services.rbitcoin.esplora` is new and serves rbitcoin's Esplora REST API on port 3002.
- It starts once rbitcoin has caught up and opened its RPC port, and serves pages once
  rbitcoin's address index has also reached the tip.
- Its store in `services.rbitcoin-space.dataDir` keeps block audits, mempool history and
  replacements that no backfill rebuilds, and the backups leave it out. See the
  [service notes](../../services.md#rbitcoinspace) to back it up.
