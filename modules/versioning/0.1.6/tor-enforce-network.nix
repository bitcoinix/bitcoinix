{ config, lib, ... }:

{
  # Services that get `nix-bitcoin.lib.allowLocalIPAddresses`: charge-lnd
  # always, the others when they enforce Tor. The nbxplorer unit is created
  # by `btcpayserver.enable`, not by the internal `nbxplorer.enable`.
  # Custom units with the restriction aren't detected: this check can't read
  # `systemd.services` without infinite recursion. docs/upgrading.md covers them.
  condition = with config.services;
    charge-lnd.enable
    || (btcpayserver.enable && nbxplorer.tor.enforce)
    || lib.any (service: service.enable && service.tor.enforce) [
      bitcoind btcpayserver clightning electrs fulcrum lnd mempool rtl
    ];
  message = ''
    Services with `tor.enforce`, charge-lnd, and custom units that use
    `nix-bitcoin.lib.allowLocalIPAddresses` or `allowTor` now reach only
    localhost and, with netns-isolation, the namespace subnet
    169.254.<addressblock>.0/24. They also resolve names in-process from
    `/etc/hosts` instead of through the local resolver sockets (nscd,
    systemd-resolved, D-Bus, Avahi). Evaluation can't detect custom units,
    so check them yourself.
    Before deploying, allow any further address a service must reach with
    `systemd.services.<service>.serviceConfig.IPAddressAllow`. This widens a
    `tor.enforce` service only without netns-isolation (the namespace
    firewall limits it otherwise), and widens charge-lnd and custom units
    either way. Add host names a service connects to to `networking.hosts`,
    or use the addresses.
  '';
}
