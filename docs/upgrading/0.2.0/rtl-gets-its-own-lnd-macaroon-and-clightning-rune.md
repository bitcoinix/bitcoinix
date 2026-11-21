#### RTL gets its own lnd macaroon and clightning rune

RTL's start copied lnd's admin macaroon to `macaroons/admin.macaroon` and clnrest's
admin rune to `clightning-admin-rune` in RTL's data dir, `/var/lib/rtl` by default. Now
RTL gets its own macaroon and rune, which allow only the calls that RTL makes, and its
start writes them to these paths. It removes the copy of a backend that RTL doesn't use.
If another app reads one of these files, it gets authorization errors after the deploy
for the calls that RTL doesn't make, or doesn't find the file. Give the app its own
credentials. For lnd, add a custom macaroon with `services.lnd.macaroons.<name>`, see
[Custom macaroons](../../services.md#custom-macaroons). For clightning, create a rune
with `lightning-cli createrune` that allows only the methods that the app needs.

With RTL on lnd, lnd restarts once during the deploy to create RTL's macaroon.
