lib: pkgs: config:

with lib;

# See `man systemd.exec` and `man systemd.resource-control` for an explanation
# of the systemd-related options available through this file.
let self = {
  # Override daemon-specific network names, passing other names through unchanged.
  networkName = overrides:
    overrides.${config.services.bitcoind.network} or config.services.bitcoind.network;

  extraConfigDescription = ''
    User-supplied extraConfig options are unsupported by bitcoinix. They may
    override managed settings or bypass security checks. You take full
    responsibility for their correctness, security and compatibility with
    bitcoinix. Prefer dedicated NixOS options when available.
  '';

  extraConfigWarning = option: "${option} is non-empty. ${self.extraConfigDescription}";

  # These settings roughly follow systemd's "strict" security profile
  defaultHardening = {
      PrivateTmp = true;
      ProtectSystem = "strict";
      # `ProtectSystem` doesn't cover these with the settings below: /run stays
      # writable, and `PrivateDevices` bind-mounts the host's /dev/shm,
      # /dev/mqueue and /dev/hugepages read-write.
      # `ReadWritePaths`, `RuntimeDirectory` and `StateDirectory` still work below
      # these paths, and device nodes like /dev/null stay writable.
      ReadOnlyPaths = [ "/run" "/dev" ];
      ProtectHome = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      MemoryDenyWriteExecute = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectClock = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      ProtectControlGroups = true;
      RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6";
      RestrictNamespaces = true;
      LockPersonality = true;
      IPAddressDeny = "any";
      PrivateUsers = true;
      RestrictSUIDSGID = true;
      RemoveIPC = true;
      RestrictRealtime = true;
      ProtectHostname = true;
      CapabilityBoundingSet = "";
      # @system-service whitelist and docker seccomp blacklist (except for "clone"
      # which is a core requirement for systemd services)
      # @system-service is defined in src/shared/seccomp-util.c (systemd source)
      SystemCallFilter = [ "@system-service" "~add_key kcmp keyctl mbind move_pages name_to_handle_at personality process_vm_readv process_vm_writev request_key setns unshare userfaultfd" ];
      SystemCallArchitectures = "native";
  };

  allowNetlink = {
    RestrictAddressFamilies = self.defaultHardening.RestrictAddressFamilies + " AF_NETLINK";
  };

  nodejs = {
    # Required for JIT compilation
    MemoryDenyWriteExecute = false;
    # Required by nodejs >= 18
    SystemCallFilter = self.defaultHardening.SystemCallFilter ++ [ "@pkey" ];
  };

  # Local name-resolution helpers reachable over a Unix socket. The systemd IP
  # filter covers IP sockets only, so a service restricted to local addresses
  # must not use these: it then resolves names in-process, where `/etc/hosts`
  # still works and queries to IP resolvers meet the filter.
  #   /run/nscd              nscd / nsncd
  #   /run/systemd/resolve   systemd-resolved varlink socket
  #   /run/dbus              D-Bus system bus
  #   /run/avahi-daemon      Avahi (mDNS), only when the user enables it
  # `security.nix` creates the first three, so their masks fail closed: without
  # a `-` prefix a missing path stops the unit from starting. Avahi's module
  # creates its directory with tmpfiles, so it's masked only when Avahi is
  # enabled. Enabling Avahi then changes the restricted units, and the switch
  # restarts them with the mask.
  localResolverPaths = [ "/run/nscd" "/run/systemd/resolve" "/run/dbus" ]
    ++ optional config.services.avahi.enable "/run/avahi-daemon";

  # Allow takes precedence over Deny.
  allowLocalIPAddresses = let
    netns = config.nix-bitcoin.netns-isolation;
  in {
    IPAddressAllow = [
      "127.0.0.1/32"
      "::1/128"
    ]
    # The namespaces of the service and its peers, and the bridge with the
    # Tor SOCKS and i2pd SAM proxies
    ++ optional netns.enable "169.254.${toString netns.addressblock}.0/24";
    InaccessiblePaths = self.localResolverPaths;
  };
  allowAllIPAddresses = { IPAddressAllow = "any"; };
  allowTor = self.allowLocalIPAddresses;
  allowedIPAddresses = onlyLocal:
    if onlyLocal
    then self.allowLocalIPAddresses
    else self.allowAllIPAddresses;

  tor = {
    proxy = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to proxy outgoing connections with Tor.";
    };
    enforce = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to enforce Tor on this service by only allowing connections
        from and to localhost and, with netns-isolation, the network namespace
        addresses `169.254.<addressblock>.0/24`. The service also can't reach
        the local name-resolution sockets (nscd, systemd-resolved, D-Bus,
        Avahi), so glibc resolves names itself: from `/etc/hosts`, and through
        a resolver only if one listens on an allowed address.
      '';
    };
  };

  script = name: src: pkgs.writers.writeBash name ''
    set -eo pipefail
    ${src}
  '';

  # A program that runs its arguments as `user` when root starts it, and as the
  # caller otherwise. CLI wrappers use it to access a service's files with the
  # rights of the service user, which owns the dirs that hold them.
  # runuser keeps the environment, which `user` can read in /proc while the
  # command runs. So pass on only PATH and TERM.
  runAsUserIfRoot = user: pkgs.writers.writeBash "run-as-user-if-root" ''
    if [[ $EUID == 0 ]]; then
      exec ${pkgs.coreutils}/bin/env -i PATH="$PATH" ''${TERM:+"TERM=$TERM"} \
        ${pkgs.util-linux}/bin/runuser -u ${escapeShellArg user} -- "$@"
    fi
    exec "$@"
  '';

  # Used for ExecStart*
  # systemd sets HOME to the home of `User=` also for `+` commands. The service
  # user can write there, so tools like curl or jq would load config files from it
  # as root.
  rootScript = name: src: "+${self.script name ''
    export HOME=/var/empty
    ${src}
  ''}";

  mkOnionService = map: {
    map = [ map ];
    version = 3;
  };

  # Convert a bind address, which may be a special INADDR_ANY address,
  # to an actual IP address
  address = addr:
    if addr == "0.0.0.0" then
      "127.0.0.1"
    else if addr == "::" then
      "::1"
    else
      addr;

  addressWithPort = addr: port: "${self.address addr}:${toString port}";

  optionalAttr = cond: name: if cond then name else null;

  mkCertExtraAltNames = cert:
    builtins.concatStringsSep "," (
      (map (domain: "DNS:${domain}") cert.extraDomains) ++
      (map (ip: "IP:${ip}") cert.extraIPs)
    );

  test = {
    mkIfTest = test: mkIf (config.tests.${test} or false);
  };

  mkAlias = default: mkOption {
    internal = true;
    readOnly = true;
    inherit default;
  };

}; in self
