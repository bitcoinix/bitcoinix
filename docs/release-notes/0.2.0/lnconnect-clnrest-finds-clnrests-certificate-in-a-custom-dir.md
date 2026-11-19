#### lnconnect-clnrest finds clnrest's certificate in a custom dir

`lnconnect-clnrest` now asks clightning for clnrest's cert dir, like RTL does. Before,
it always read `server.pem` from clightning's network dir. So with `clnrest-certs` set,
it failed or put the wrong certificate into direct connection URLs. Regenerate such URLs.
When clightning doesn't answer, for example because it's stopped, `lnconnect-clnrest`
prints a warning and uses the network dir, as before.
