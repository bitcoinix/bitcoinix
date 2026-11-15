#### rbitcoin service (experimental)

New service: [rbitcoin](../../services.md#rbitcoin) 0.9.2, an experimental Bitcoin full node
in Rust with built-in Electrum and Esplora servers. Enable it with
`services.rbitcoin.enable = true;`, or make it mempool's node and Electrum server with
`services.mempool.electrumServer = "rbitcoin"`. bitcoind's `txindex` is then no
longer forced on by mempool. Read [the service notes](../../services.md#rbitcoin) first: it
keeps its own data directory, and its RPC cookie is an admin credential.
