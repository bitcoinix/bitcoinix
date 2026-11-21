#### systemd holds RTL's port while RTL is stopped

Without netns-isolation, any local user could take RTL's port while RTL was stopped,
for example during maintenance of lnd or clightning, and collect the RTL password
with a fake login page. RTL now listens on a unix socket, and systemd holds
`services.rtl.address` and `port` from boot on with a socket unit, `rtl-proxy-*.socket`.
`rtl-proxy.service` forwards each connection to RTL. The address must be a numeric IP
address without a zone ID, or the system build fails. All clients now share RTL's login
lockout. The first switch to this version leaves the port free for a moment. With
netns-isolation, RTL listens on its namespace's address as before. See
[Upgrading to config version 0.2.0](../../upgrading/0.2.0/systemd-holds-rtls-port-while-rtl-is-stopped.md).
