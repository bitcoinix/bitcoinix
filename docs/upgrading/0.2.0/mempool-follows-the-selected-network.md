#### Mempool follows the selected network

Mempool now identifies as regtest in both its backend and frontend when
`services.bitcoind.network = "regtest";`. Previously it identified as mainnet
while connecting to the regtest node. It automatically clears disk caches
labelled mainnet and reloads data from its backend after restart.

Review overrides in `services.mempool.frontend.settings`: regtest defaults to
`MAINNET_ENABLED = false`, `REGTEST_ENABLED = true` and `ROOT_NETWORK = "regtest"`.
Remove conflicting overrides unless needed for a custom deployment. If you set
`services.mempool.frontend.staticContentRoot`, update that custom frontend too.
The web interface stays at the same URL; reload it after deploying.
