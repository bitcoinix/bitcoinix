#### lnd's REST onion service forwards to a Unix socket

With `services.lnd.lndconnect.onion`, lnd also serves REST on the Unix socket
`/run/lnd-rest/rest.sock`, and the `lnd-rest` onion service forwards to this socket
instead of lnd's REST port. Only lnd can create the socket, so the onion service reaches
only lnd, also while lnd restarts. Only lnd and Tor can open the socket's directory. The
onion address and port stay the same, so wallets don't need to pair again. lnd keeps
listening on `services.lnd.restAddress` for RTL and local clients.
