{ config, ... }:

let
  inherit (config.services) rtl;
in
{
  # With netns-isolation, RTL keeps listening on its namespace's address
  condition = rtl.enable && !config.bitcoinix.netns-isolation.enable;
  # Names no configured address, since it can't tell a host name from an IP address
  message = ''
    RTL now listens on a unix socket, and systemd holds `services.rtl.address`
    and `port` for it with a socket unit, `rtl-proxy-*.socket`, also while RTL
    is stopped. The address must be a numeric IP address without a zone ID,
    like `127.0.0.1`. A host name like `localhost`, a zone ID like `%lo` or a
    socket path now fails the system build with an error that names the address.
    The first switch to this version stops RTL before it starts the socket unit,
    so another local user could take the port in between. Deploy with
    `nixos-rebuild boot` and reboot. After the reboot or a switch, check that
    `systemctl list-units --all 'rtl-proxy-*.socket'` shows the socket unit
    active. RTL now ignores `PORT` and `HOST` in its environment. Five failed
    logins from any client now lock out all clients for 30 minutes. Once the
    socket unit is active, use its address and port in the SSH tunnel to RTL,
    and not `localhost`. By default that's `127.0.0.1:3000`. For `0.0.0.0` use
    `127.0.0.1`, and for `::` use `[::1]`.
  '';
}
