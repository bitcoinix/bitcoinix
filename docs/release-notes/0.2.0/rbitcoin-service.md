#### rbitcoin service (experimental)

New service: [rbitcoin](../../services.md#rbitcoin) 0.9.2, an experimental Bitcoin full node
in Rust with built-in Electrum and Esplora servers. It runs beside bitcoind, in its own
data directory; enabling it changes no other service.

- Turn it on with `services.rbitcoin.enable = true;`.
- mempool can use it as its backend: `services.mempool.electrumServer` now takes
  `"rbitcoin"` besides `"electrs"` (the default) and `"fulcrum"`. With `"rbitcoin"`,
  mempool uses rbitcoin as both its node and its Electrum server and enables it for you;
  it no longer turns on bitcoind's `txindex` or electrs, and gets no bitcoind RPC user.
  Existing mempool setups keep electrs and are unchanged.

Read [the service notes](../../services.md#rbitcoin) first: its RPC cookie is an admin
credential.
