{ config, lib, pkgs, ... }:

with lib;
let
  # Services that get `nix-bitcoin.lib.allowLocalIPAddresses` (local-only
  # network access plus the resolver-socket masks): charge-lnd always, the
  # others when they enforce Tor.
  # The nbxplorer unit is created by `btcpayserver.enable`, not by the internal
  # `nbxplorer.enable`, so gate it on the former.
  usesLocalOnly = with config.services;
    charge-lnd.enable
    || (btcpayserver.enable && nbxplorer.tor.enforce)
    || any (service: service.enable && service.tor.enforce) [
      bitcoind btcpayserver clightning electrs fulcrum lnd mempool rtl
    ];

  # nscd's `RuntimeDirectory` owns /run/nscd as its service user, so match that
  # when nscd is enabled and fall back to root otherwise.
  nscdDir = path: with config.services.nscd;
    if enable then "d ${path} 0755 ${user} ${group} -"
    else "d ${path} 0755 root root -";
in
{
  options = {
    nix-bitcoin.security.dbusHideProcessInformation = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Only allow users with group `proc` to retrieve systemd unit information like
        cgroup paths (i.e. (sub)process command lines) via D-Bus.

        This mitigates a systemd security issue where (sub)process command lines can
        be retrieved by services even when their access to /proc is restricted
        (via ProtectProc).

        This option works by restricting the D-Bus method `GetUnitProcesses`, which
        is also used internally by {command}`systemctl status`.
      '';
    };
  };

  config = mkMerge [
  # Services restricted to local addresses (`nix-bitcoin.lib.allowLocalIPAddresses`)
  # are denied the local name-resolution sockets via `InaccessiblePaths`. These
  # masks have no `-` prefix, so a missing path makes the unit fail to start
  # rather than run unmasked. Create each directory independently of its
  # resolver so the units start. Each rule matches the ownership the resolver's
  # own `RuntimeDirectory` would use, so repeated tmpfiles runs don't fight it.
  (mkIf usesLocalOnly {
    systemd.tmpfiles.rules = [
      (nscdDir "/run/nscd")
      (if config.services.resolved.enable
       then "d /run/systemd/resolve 0755 systemd-resolve systemd-resolve -"
       else "d /run/systemd/resolve 0755 root root -")
      "d /run/dbus 0755 root root -"
    ];
  })

  # nscd removes its runtime directory when it stops, which detaches the mask in
  # a running local-only service. Keep the directory so the mask survives an nscd
  # restart. `mkDefault` lets a user override the lifecycle if they must.
  (mkIf (usesLocalOnly && config.services.nscd.enable) {
    systemd.services.nscd.serviceConfig = {
      RuntimeDirectoryPreserve = mkDefault true;
      # Preserving the directory also keeps a stale pid file from glibc's nscd
      # (nsncd doesn't use one); remove it so a restart doesn't read it.
      ExecStartPre = mkIf (!config.services.nscd.enableNsncd)
        [ "+${pkgs.coreutils}/bin/rm -f /run/nscd/nscd.pid" ];
    };
  })

  (mkIf config.nix-bitcoin.security.dbusHideProcessInformation {
    users.groups.proc = {};
    nix-bitcoin.operator.groups = [ "proc" ]; # Enable operator access to systemd-status

    services.dbus.packages = lib.mkAfter [ # Apply at the end to override the default policy
      (pkgs.writeTextDir "etc/dbus-1/system.d/dbus.conf" ''
        <busconfig>
          <policy context="default">
            <deny
              send_destination="org.freedesktop.systemd1"
              send_interface="org.freedesktop.systemd1.Manager"
              send_member="GetUnitProcesses"
            />
          </policy>
          <policy group="proc">
            <allow
              send_destination="org.freedesktop.systemd1"
              send_interface="org.freedesktop.systemd1.Manager"
              send_member="GetUnitProcesses"
            />
          </policy>
        </busconfig>
      '')
    ];
  })
  ];
}
