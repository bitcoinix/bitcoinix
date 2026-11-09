{ config, lib, pkgs, ... }:

with lib;
let
  options.services.lnd = {
    enable = mkEnableOption "Lightning Network daemon, a Lightning Network implementation in Go";
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen for peer connections";
    };
    port = mkOption {
      type = types.port;
      default = 9735;
      description = "Port to listen for peer connections";
    };
    rpcAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen for RPC connections.";
    };
    rpcPort = mkOption {
      type = types.port;
      default = 10009;
      description = "Port to listen for gRPC connections.";
    };
    restAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen for REST connections.";
    };
    restPort = mkOption {
      type = types.port;
      default = 8080;
      description = "Port to listen for REST connections.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/lnd";
      description = "The data directory for LND.";
    };
    networkDir = mkOption {
      readOnly = true;
      default = "${cfg.dataDir}/chain/bitcoin/${bitcoind.network}";
      description = "The network data directory.";
    };
    tor-socks = mkOption {
      type = types.nullOr types.str;
      default = if cfg.tor.proxy then config.nix-bitcoin.torClientAddressWithPort else null;
      description = "Socks proxy for connecting to Tor nodes";
    };
    certificate = {
      extraIPs = mkOption {
        type = with types; listOf str;
        default = [];
        example = [ "60.100.0.1" ];
        description = ''
          Extra `subjectAltName` IPs added to the certificate.
          This works the same as lnd option {option}`tlsextraip`.
        '';
      };
      extraDomains = mkOption {
        type = with types; listOf str;
        default = [];
        example = [ "example.com" ];
        description = ''
          Extra `subjectAltName` domain names added to the certificate.
          This works the same as lnd option {option}`tlsextradomain`.
        '';
      };
    };
    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        autopilot.active=1
      '';
      description = ''
        Extra lines appended to {file}`lnd.conf`.

        ${nbLib.extraConfigDescription}

        See here for all available options:
        https://github.com/lightningnetwork/lnd/blob/master/sample-lnd.conf
      '';
    };
    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.lnd;
      defaultText = "config.nix-bitcoin.pkgs.lnd";
      description = "The package providing lnd binaries.";
    };
    cli = mkOption {
      default = pkgs.writers.writeBashBin "lncli"
        # Switch user because lnd makes datadir contents readable by user only
        ''
          ${runAsUser} ${cfg.user} ${cfg.package}/bin/lncli \
            --rpcserver ${cfg.rpcAddress}:${toString cfg.rpcPort} \
            --tlscertpath '${cfg.certPath}' \
            --macaroonpath '${networkDir}/admin.macaroon' "$@"
        '';
      defaultText = "(See source)";
      description = "Binary to connect with the lnd instance.";
    };
    getPublicAddressCmd = mkOption {
      type = types.str;
      default = "";
      description = ''
        Bash expression which outputs the public service address to announce to peers.
        If left empty, no address is announced.
      '';
    };
    user = mkOption {
      type = types.str;
      default = "lnd";
      description = "The user as which to run LND.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      description = "The group as which to run LND.";
    };
    certPath = mkOption {
      readOnly = true;
      default = "${secretsDir}/lnd-cert";
      description = "LND TLS certificate path.";
    };
    tor = nbLib.tor;
  };

  cfg = config.services.lnd;
  nbLib = config.nix-bitcoin.lib;
  secretsDir = config.nix-bitcoin.secretsDir;
  runAsUser = config.nix-bitcoin.runAsUserCmd;
  lndinit = "${config.nix-bitcoin.pkgs.lndinit}/bin/lndinit";

  bitcoind = config.services.bitcoind;

  bitcoindRpcAddress = nbLib.address bitcoind.rpc.address;
  networkDir = cfg.networkDir;
  configFile = pkgs.writeText "lnd.conf" ''
    datadir=${cfg.dataDir}
    tlscertpath=${cfg.certPath}
    tlskeypath=${secretsDir}/lnd-key

    # We're logging via journald
    logging.file.disable=1
    logging.console.no-timestamps=1

    listen=${toString cfg.address}:${toString cfg.port}
    rpclisten=${cfg.rpcAddress}:${toString cfg.rpcPort}
    restlisten=${cfg.restAddress}:${toString cfg.restPort}

    bitcoin.${bitcoind.network}=1
    bitcoin.node=bitcoind

    ${optionalString (cfg.tor.proxy) "tor.active=true"}
    ${optionalString (cfg.tor-socks != null) "tor.socks=${cfg.tor-socks}"}

    bitcoind.rpchost=${bitcoindRpcAddress}:${toString bitcoind.rpc.port}
    bitcoind.rpcuser=${bitcoind.rpc.users.public.name}
    bitcoind.zmqpubrawblock=${zmqHandleSpecialAddress bitcoind.zmqpubrawblock}
    bitcoind.zmqpubrawtx=${zmqHandleSpecialAddress bitcoind.zmqpubrawtx}

    wallet-unlock-password-file=${secretsDir}/lnd-wallet-password

    ${cfg.extraConfig}
  '';

  zmqHandleSpecialAddress = builtins.replaceStrings [ "0.0.0.0" "[::]" ] [ "127.0.0.1" "[::1]" ];

  # lnd adds port 9735 to an external address without a port, but a public
  # onion service forwards its own port. Custom addresses stay as they are,
  # because they may carry a port of their own.
  onionPortSuffix = optionalString
    ((config.nix-bitcoin.onionServices.lnd.enable or false)
      && config.nix-bitcoin.onionServices.lnd.public
      && onionPeerMapping != null)
    ":${toString onionPeerMapping.port}";
  # The onion mapping to lnd's peer port. Other mappings may come first.
  # A mapping without a target forwards to its own port.
  onionPeerMapping = findFirst (mapping: (mapping.target.port or mapping.port) == cfg.port) null
    (config.services.tor.relay.onionServices.lnd.map or []);
in {

  inherit options;

  config = mkIf cfg.enable {
    warnings = optional (cfg.extraConfig != "")
      (nbLib.extraConfigWarning "services.lnd.extraConfig");

    assertions = [
      { assertion =
          !(config.services ? clightning)
          || !config.services.clightning.enable
          || config.services.clightning.port != cfg.port;
        message = ''
          LND and clightning can't both bind to lightning port 9735. Either
          disable LND/clightning or change services.clightning.port or
          services.lnd.port to a port other than 9735.
        '';
      }
    ];

    services.bitcoind = {
      enable = true;

      # Increase rpc thread count due to reports that lightning implementations fail
      # under high bitcoind rpc load
      rpc.threads = 16;

      zmqpubrawblock = mkDefault "tcp://${bitcoindRpcAddress}:28332";
      zmqpubrawtx = mkDefault "tcp://${bitcoindRpcAddress}:28333";
    };

    environment.systemPackages = [ cfg.package (hiPrio cfg.cli) ];

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0770 ${cfg.user} ${cfg.group} - -"
    ];

    services.lnd.certificate.extraIPs = mkIf (cfg.rpcAddress != "127.0.0.1") [ "${cfg.rpcAddress}" ];

    systemd.services.lnd = {
      # `wantedBy` bitcoind: a deploy that changes the bitcoind unit stops and
      # starts bitcoind. `requires` propagates the stop to this unit, and on
      # production nodes the unit stayed down after such a switch. Being wanted
      # by bitcoind ties this unit's start to bitcoind's own start job, ordered
      # after it. `requires` stays so that an explicit `systemctl stop bitcoind`
      # keeps every dependent down, with no restart that could pull bitcoind
      # back up.
      wantedBy = [ "multi-user.target" "bitcoind.service" ];
      requires = [ "bitcoind.service" ];
      after = [ "bitcoind.service" "nix-bitcoin-secrets.target" ];
      # Go 1.24 and later open every listener as Multipath TCP when the kernel
      # supports it, so lnd's P2P, RPC and REST ports become MPTCP sockets
      # without lnd asking for it. MPTCP adds kernel attack surface on the
      # public P2P port: the exploit published for CVE-2026-98432 goes through
      # an MPTCP listener. lnd does not need MPTCP, so turn it off in the Go
      # runtime; the sockets fall back to plain TCP.
      environment.GODEBUG = "multipathtcp=0";
      preStart = ''
        conf=$(
          cat ${configFile}
          echo "bitcoind.rpcpass=$(cat ${secretsDir}/bitcoin-rpcpassword-public)"
          ${optionalString (cfg.getPublicAddressCmd != "") ''
            echo "externalip=$(${cfg.getPublicAddressCmd})${onionPortSuffix}"
          ''}
        )
        install -T -m 600 <(echo "$conf") '${cfg.dataDir}/lnd.conf'

        if [[ ! -f ${networkDir}/wallet.db ]]; then
          seed='${cfg.dataDir}/lnd-seed-mnemonic'

          if [[ ! -f "$seed" ]]; then
            echo "Create lnd seed"
            (umask u=r,go=; ${lndinit} gen-seed > "$seed")
          fi

          echo "Create lnd wallet"
          ${lndinit} -v init-wallet \
            --file.seed="$seed" \
            --file.wallet-password='${secretsDir}/lnd-wallet-password' \
            --init-file.output-wallet-dir='${cfg.networkDir}'
        fi
      '';
      serviceConfig = nbLib.defaultHardening // {
        Type = "notify";
        ExecStart = "${cfg.package}/bin/lnd --configfile='${cfg.dataDir}/lnd.conf'";
        User = cfg.user;
        TimeoutSec = "15min";
        # `always`, not `on-failure`: when bitcoind stays unreachable, lnd's
        # chain backend health check gives up and lnd shuts down cleanly with
        # exit status 0. `on-failure` then left lnd down after bitcoind came
        # back. `systemctl stop lnd` still stops lnd for good, because an
        # explicit stop never triggers `Restart=`.
        Restart = "always";
        RestartSec = "10s";
        ReadWritePaths = [ cfg.dataDir ];
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = [ "bitcoinrpc-public" ];
      home = cfg.dataDir; # lnd creates .lnd dir in HOME
    };
    users.groups.${cfg.group} = {};
    nix-bitcoin.operator = {
      groups = [ cfg.group ];
      allowRunAsUsers = [ cfg.user ];
    };

    nix-bitcoin.secrets = {
      lnd-wallet-password.user = cfg.user;
      lnd-key.user = cfg.user;
      lnd-cert.user = cfg.user;
      lnd-cert.permissions = "444"; # world readable
    };
    # Advantages of manually pre-generating certs:
    # - Reduces dynamic state
    # - Enables deployment of a mesh of server plus client nodes with predefined certs
    nix-bitcoin.generateSecretsCmds.lnd = ''
      makePasswordSecret lnd-wallet-password
      makeCert lnd '${nbLib.mkCertExtraAltNames cfg.certificate}'
    '';
  };
}
