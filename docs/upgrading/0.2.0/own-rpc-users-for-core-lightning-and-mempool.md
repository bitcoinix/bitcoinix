#### Own RPC users for Core Lightning and mempool

Core Lightning and mempool now connect to bitcoind as their own RPC users,
`clightning` and `mempool`. Before, they connected as the `public` user and added
the methods they need to its whitelist: `getblockfrompeer` for Core Lightning's
bcli plugin and `gettxoutsetinfo` for mempool. All services of the `public` user
share its whitelist, so electrs, Fulcrum, lnd and the others could call these
methods too. `gettxoutsetinfo` can keep bitcoind busy for minutes. Now the
`public` user has only the base whitelist, and each new user has the base
whitelist plus the method of its service.

Each new user has its own password and HMAC in the
[secrets dir](../../configuration.md#secrets-dir): `bitcoin-rpcpassword-clightning`
and `bitcoin-HMAC-clightning`, and `bitcoin-rpcpassword-mempool` and
`bitcoin-HMAC-mempool`. What you have to do depends on your setup:

- With `nix-bitcoin.generateSecrets = true` or the krops deployment shell, and
  bitcoind on the same node, bitcoinix creates these files, and there's nothing
  else to do. No option marks a bitcoind on another node, so evaluation reports
  this change for every config with Core Lightning or mempool.
- If you supply secrets yourself, create these files for the services you use
  before deploying. Write a new password to `bitcoin-rpcpassword-<user>`, and
  its HMAC to `bitcoin-HMAC-<user>`: the `<salt>$<hmac>` part of the `rpcauth=`
  line that Bitcoin Core's `share/rpcauth/rpcauth.py` prints. With
  `nix-bitcoin.setupSecrets`, a missing file fails setup, and then no service
  can read its secrets.
- With the `bitcoind-remote.nix` preset, create the new users on the other node
  as described in [Use bitcoind from another node](../../configuration.md#use-bitcoind-from-another-node),
  with the whitelists in `services.bitcoind.rpc.users.clightning.rpcwhitelist` and
  `services.bitcoind.rpc.users.mempool.rpcwhitelist`. Set
  `services.bitcoind.rpc.users.<user>.name` if a user has another name there.
  Save their passwords to `bitcoin-rpcpassword-<user>` on this node. With
  `nix-bitcoin.generateSecrets = true`, bitcoinix creates a password when the
  file is missing, and `bitcoin-HMAC-<user>` then holds the part after
  `rpcauth=<name>:` for the other node. Without it, write the HMAC as above, or
  create an empty `bitcoin-HMAC-<user>` and set
  `nix-bitcoin.secrets.bitcoin-HMAC-<user>.allowEmpty = true`, since this node
  doesn't use it.

With bitcoind on another node, its whitelists still have the methods that
bitcoinix added before. Remove `getblockfrompeer` and `gettxoutsetinfo` from the
whitelist of the public user there, if it has them, whatever your new config
enables. If you use BTCPay Server, set the whitelist of its user there again
from `services.bitcoind.rpc.users.btcpayserver.rpcwhitelist`. It builds on the
public whitelist, so with mempool it had `gettxoutsetinfo` too.
