#### Own RPC users for Core Lightning and mempool

Core Lightning and mempool added `getblockfrompeer` and `gettxoutsetinfo` to the
whitelist of the shared `public` RPC user, so every other service of that user
could call them too. They now connect to bitcoind as their own users, `clightning`
and `mempool`, and the `public` user keeps the base whitelist. Setups that supply
secrets themselves need the secrets of the new users, and setups with bitcoind on
another node also need the users there, see the
[upgrade notes](../../upgrading/0.2.0/own-rpc-users-for-core-lightning-and-mempool.md).
