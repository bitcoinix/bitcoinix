#### NBXplorer 2.6.23

bitcoinix now packages NBXplorer itself and updates it to 2.6.23. This release fixes an
indexer that can hang after a PostgreSQL error, so that BTCPay Server sees no new
blocks or payments until NBXplorer restarts. The flake's `nbxplorer` package and its
`overlays.default` now have this version, and `pinned.nbxplorer` stays the nixpkgs
package.
