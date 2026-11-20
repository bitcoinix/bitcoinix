# Reserve a dashboard's HTTP port even when it is stopped. Otherwise another
# local user could serve a login page there and collect the operator's password.
# With netns-isolation only root can enter the dashboard's network namespace,
# so the dashboard listens on TCP itself.
{ name, socketPath, user }:
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.${name};
  dataDir = cfg.dataDir or null;
  nbLib = config.bitcoinix.lib;
  # ListenStream needs brackets around an IPv6 address.
  address = if hasInfix ":" cfg.address then "[${cfg.address}]" else cfg.address;
  listenAddress = "${address}:${toString cfg.port}";
  # A switch replaces a removed socket unit, but doesn't restart a changed one.
  proxy = "${name}-proxy";
  socket = "${proxy}-${substring 0 8 (builtins.hashString "sha256" listenAddress)}";
  # Apply the dashboard's IP filters to the socket that systemd passes in.
  ipFilters = filterAttrs (key: _: elem key [ "IPAddressAllow" "IPAddressDeny" ])
    config.systemd.services.${name}.serviceConfig;
in {
  config = mkIf (cfg.enable && !config.bitcoinix.netns-isolation.enable) {
    assertions = [{
      assertion = cfg.port != 0;
      message = ''
        `services.${name}.port` must not be 0. The systemd socket needs a fixed
        TCP port. Omit this setting to use the default port.
      '';
    }];

    systemd.sockets.${socket} = {
      wantedBy = [ "sockets.target" ];
      listenStreams = [ listenAddress ];
      socketConfig = ipFilters // {
        Service = "${proxy}.service";
        # Listen before the chosen address exists, e.g. a WireGuard address.
        FreeBind = true;
        # Match Node's dual-stack listener, regardless of net.ipv6.bindv6only.
        BindIPv6Only = "both";
      };
    };

    # systemd skips addresses it can't parse. A path or @name creates a Unix
    # socket instead. Either would leave the HTTP port unreserved.
    system.checks = [
      (pkgs.runCommand "check-${name}-address" { inherit (cfg) address; } ''
        ${pkgs.buildPackages.python3}/bin/python3 -I -c '
        import ipaddress, os, sys
        address = os.environ["address"]
        try:
            ipaddress.ip_address(address)
            valid = "%" not in address
        except ValueError:
            valid = False
        if not valid:
            sys.exit("Error: services.${name}.address must be a numeric IP address without "
                     f"a zone ID, like 127.0.0.1 or ::1, not {address!r}")
        '
        touch $out
      '')
    ];

    systemd.services.${proxy} = {
      requires = [ "${socket}.socket" ];
      # The proxy masks the secrets directory, which must already exist.
      after = [ "${socket}.socket" "nix-bitcoin-secrets.target" ];
      # Keep the proxy running until daemon-reload so an incoming connection
      # during a switch can't start the previous unit again.
      stopIfChanged = false;
      # A service hitting its start limit would close the listening socket.
      startLimitIntervalSec = 0;
      serviceConfig = nbLib.defaultHardening // {
        ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd ${socketPath}";
        # The dashboard grants this user access to its Unix socket.
        User = user;
        # Fail closed if a mask is missing. The socket stays held while the
        # proxy retries. It needs neither the database nor local resolvers.
        # An empty InaccessiblePaths= resets all preceding masks in systemd.
        InaccessiblePaths = nbLib.localResolverPaths ++ optional (dataDir != null && dataDir != "") dataDir
          ++ [ config.bitcoinix.secretsDir ];
        PrivateNetwork = true;
        RestrictAddressFamilies = "AF_UNIX";
        SystemCallFilter = nbLib.defaultHardening.SystemCallFilter ++ [ "name_to_handle_at" ];
        Restart = "always";
        RestartSec = "1s";
        RestartSteps = 5;
        RestartMaxDelaySec = "1min";
      };
    };
  };
}
