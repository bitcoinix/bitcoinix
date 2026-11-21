#### systemd holds RTL's port while RTL is stopped

Without netns-isolation, RTL now listens on a unix socket, and systemd holds
`services.rtl.address` and `port` for it with a socket unit, `rtl-proxy-*.socket`.
`rtl-proxy.service` forwards each connection to RTL. The SSH tunnel and the onion
service work as before. In the tunnel, use the address and port that systemd holds. By
default that's `127.0.0.1:3000`, as in [Connect to RTL](../../services.md#connect-to-rtl).
If you set another address or port, use those, with `127.0.0.1` for `0.0.0.0` and
`[::1]` for `::`. With `localhost`, sshd may connect to `[::1]:3000`, which systemd
doesn't hold with the default address.

- `services.rtl.address` must be a numeric IPv4 or IPv6 address, without brackets
  and without a zone ID like `%lo`. A host name like `localhost`, a zone ID or a
  socket path now fails the system build with an error that names the address. So if
  you set a host name or a zone ID, set a numeric IP address like `127.0.0.1`.
- The first switch to this version stops RTL before it starts the socket unit. The
  port is free in between, and another local user could take it. To avoid this,
  deploy with `nixos-rebuild boot` and reboot. After the reboot or a switch, check
  that `systemctl list-units --all 'rtl-proxy-*.socket'` shows the socket unit
  `loaded` and `active`. A switch back to an older version has the same gap, and so
  has a later switch that changes `services.rtl.address` or `port`.
- RTL now ignores `PORT` and `HOST` in its environment, also from an
  `EnvironmentFile`. Use `services.rtl.address` and `port` instead.
- RTL sees no client addresses through the proxy. So five failed logins from any
  client lock out all clients for 30 minutes. Before, this applied to all clients on
  localhost.
