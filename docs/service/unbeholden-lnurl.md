# Unbeholden LNURL

> The examples assume the `secure-node.nix` preset; see [Using services](../services.md).

[Unbeholden LNURL](https://github.com/unbeholdendev/unbeholden-lnurl) serves Lightning
Addresses through your local LND or Core Lightning node.

```nix
services.unbeholden-lnurl = {
  enable = true;
  backend = "lnd";
  settings.addresses.satoshi = {
    description = "Lightning payments";
    min_sendable = 1000;
    max_sendable = 1000000000;
  };
};
```

Use `backend = "clightning";` for Core Lightning. The module enables the selected node and
creates credentials limited to the RPCs needed by the configured features. Core
Lightning revokes the service's rune when you disable the service or switch it to LND.
When Core Lightning starts with a new or older database, for example after a recovery,
the service gets a new rune, and the old one stays valid: its ID can now belong to
another rune, so bitcoinix doesn't revoke it.

The HTTP listener defaults to `127.0.0.1:8081`. Put an HTTPS reverse proxy in front
for a public Lightning Address. Set `settings.trusted_proxies` to the proxy's IP
addresses or CIDRs if it forwards `X-Forwarded-Host` or `X-Forwarded-For`.
With namespace isolation, use the service's namespace address as the proxy target.
Onion domains can use HTTP through `bitcoinix.onionServices.unbeholden-lnurl.enable`.

`settings.withdraw` defines vouchers, `settings.notifications.ntfy` enables payment
notifications, and `settings.nostr = {};` enables zap receipts. Amounts are in
millisatoshis. `settings` takes the keys of the
[example config](https://github.com/unbeholdendev/unbeholden-lnurl/blob/main/config.example.yaml),
except `listen`, `state_dir` and the node connection, which the module sets.

The config is world-readable in the Nix store. Store an ntfy token in a runtime file
and set `settings.notifications.ntfy.token_file` to its path. On a public ntfy server,
anyone who knows the topic can read the notifications, so choose a topic that is hard
to guess or protect it with a token. The module generates persistent verification,
voucher and Nostr keys through Bitcoinix secrets. Setting `settings.withdraw_secret`
instead skips the voucher key but puts the secret in the world-readable store.

To print the unclaimed vouchers with their URLs, run `sudo unbeholden-lnurl-vouchers`.

Keep `/var/lib/unbeholden-lnurl` and the generated secrets across upgrades. This
preserves voucher claims, settlement cursors and zap receipts. Changing a voucher
secret changes its URLs; changing the verification key invalidates old verify URLs.
Treat voucher URLs as bearer secrets. A restored backup restores the voucher secret
but not the claims made since the backup, so those vouchers can be claimed again.

With vouchers, the service can pay any invoice from the node's Lightning balance
(LND `SendPaymentV2`, Core Lightning `pay`). Only the service itself enforces the
voucher amounts.

Rate limits apply per client address. Behind the onion service every client comes
from Tor's address, so they all share one limit, and one client can use it up.

Set `services.unbeholden-lnurl.tor.proxy = true;` to send notifications and Nostr
publishing through Tor. The local node connection stays direct. Zap receipts go to
relays that the payer chooses, so without the proxy anyone who pays a zap learns the
node's IP address, even when the Lightning Address is published only as an onion.
