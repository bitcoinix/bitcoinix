#### Services stop when their public address command fails

bitcoind, lnd and clightning now run `getPublicAddressCmd` before they write their
config, and fail to start when the command fails or prints nothing. The journal then
shows the error of the command, or that it printed no address.

With a public onion service, this happens when the `onion-addresses` service can't
read the onion address of the service. The services also failed then before, but
later and with an error that didn't name the missing address. bitcoind failed with
`Cannot resolve -externalip address: ''` and clightning with `Cannot use wildcard
address`. lnd opened its wallet and then failed with `unable to encode IP <nil>`.

A custom command that printed an address and then failed worked before. It now stops
the service.
