#### RTL gets its own lnd macaroon and clightning rune

RTL used lnd's admin macaroon and clnrest's admin rune. Now it gets a macaroon
(`services.lnd.macaroons.rtl`) that allows only the lnd RPCs that it calls, and a rune
that allows only the clightning methods that it calls. RTL can still send funds and
open and close channels, but it can't bake macaroons, create runes, stop lnd, delete
lnd's payment history or use lnd's signer RPCs. The macaroon's permissions for the
RPCs of `invoicesrpc` and `walletrpc` use the new option
`services.lnd.macaroons.<name>.optionalPermissions`, so RTL also starts with an lnd
package that lacks these build tags. bitcoinix creates the rune once, at
`rtl-rune` in clightning's network dir. When an update changes the methods that RTL
needs, RTL's start creates a new rune and revokes the old one. RTL's start replaces its
copies of the admin credentials, or removes the copy of a backend that RTL doesn't use.
The admin macaroon and the admin rune themselves stay valid. See
[RTL's backend credentials](../../services.md#backend-credentials). An app that reads
RTL's copies needs its own credentials now, see the
[upgrade notes](../../upgrading/0.2.0/rtl-gets-its-own-lnd-macaroon-and-clightning-rune.md).
