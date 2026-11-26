#### Lightning Terminal

Add `services.lightning-terminal` (`litd` 0.17.11) for LND. It runs in remote mode
against `services.lnd` with a dedicated LND macaroon and `services.lnd.rpcMiddleware`,
serves the HTTPS web UI, supports Lightning Node Connect sessions for
`https://terminal.lightning.engineering/` (including over Tor), enables Faraday by
default, and provides opt-in options for Loop, Pool, Taproot Assets, and Autopilot.
