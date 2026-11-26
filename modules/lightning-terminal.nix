{ config, lib, pkgs, ... }:

with lib;
let
  options.services.lightning-terminal = {
    enable = mkEnableOption "Lightning Terminal (litd), a web interface, Lightning Node Connect gateway, and subserver manager for LND";
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      apply = s:
        if builtins.match "[[][^][[:space:]]+[]]" s != null then
          substring 1 (stringLength s - 2) s
        else
          s;
      description = "Address to listen on for HTTPS, gRPC, and gRPC-Web connections. IPv6 addresses may be given with or without brackets.";
    };
    port = mkOption {
      type = types.port;
      default = 8443;
      description = "Port to listen on for HTTPS, gRPC, and gRPC-Web connections.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/lightning-terminal";
      description = "The data directory for Lightning Terminal and its integrated subservers.";
    };
    networkDir = mkOption {
      type = types.path;
      readOnly = true;
      default = "${cfg.dataDir}/${litNetwork}";
      defaultText = literalExpression ''"''${dataDir}/''${network}"'';
      description = "The network data directory.";
    };
    faraday = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable the integrated Faraday channel accounting and analytics subserver.";
      };
      connectBitcoin = mkEnableOption "connecting Faraday directly to bitcoind for on-chain transaction lookups (enables services.bitcoind.txindex)";
    };
    loop.enable = mkEnableOption "the integrated Lightning Loop submarine swap subserver";
    pool.enable = mkEnableOption "the integrated Lightning Pool channel marketplace subserver";
    taproot-assets.enable = mkEnableOption "the integrated Taproot Assets (tapd) subserver";
    autopilot.enable = mkEnableOption "the Lightning Labs Autopilot session client";
    certificate = {
      extraIPs = mkOption {
        type = with types; listOf str;
        default = [];
        example = [ "192.168.1.20" ];
        description = ''
          Extra `subjectAltName` IPs added to the certificate.
          This works the same as litd option {option}`tlsextraip`.
        '';
      };
      extraDomains = mkOption {
        type = with types; listOf str;
        default = [];
        example = [ "example.com" ];
        description = ''
          Extra `subjectAltName` domain names added to the certificate.
          This works the same as litd option {option}`tlsextradomain`.
        '';
      };
    };
    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        enablerest=true
      '';
      description = ''
        Extra lines appended to {file}`lit.conf`.

        ${nbLib.extraConfigDescription}
      '';
    };
    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.lightning-terminal;
      defaultText = literalExpression "config.nix-bitcoin.pkgs.lightning-terminal";
      description = "The package providing lightning-terminal binaries.";
    };
    cli = mkOption {
      type = types.package;
      default = pkgs.writers.writeBashBin "litcli" ''
        args=(
          --rpcserver ${escapeShellArg dialEndpoint}
          --network ${escapeShellArg litNetwork}
          --tlscertpath ${escapeShellArg cfg.certPath}
          --macaroonpath ${escapeShellArg "${cfg.networkDir}/lit.macaroon"}
        )
        if [[ $EUID == 0 ]]; then
          exec ${nbLib.runAsUserIfRoot cfg.user} ${cfg.package}/bin/litcli "''${args[@]}" "$@"
        elif [[ $(${pkgs.coreutils}/bin/id -un) == ${escapeShellArg cfg.user} ]]; then
          exec ${cfg.package}/bin/litcli "''${args[@]}" "$@"
        else
          exec ${runAsUser} ${cfg.user} ${cfg.package}/bin/litcli "''${args[@]}" "$@"
        fi
      '';
      defaultText = "(See source)";
      description = "Binary to connect with the Lightning Terminal instance.";
    };
    user = mkOption {
      type = types.str;
      default = "lightning-terminal";
      description = "The user as which to run Lightning Terminal.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      defaultText = literalExpression "user";
      description = "The group as which to run Lightning Terminal.";
    };
    certPath = mkOption {
      type = types.path;
      readOnly = true;
      default = "${secretsDir}/lightning-terminal-cert";
      defaultText = literalExpression ''"''${config.nix-bitcoin.secretsDir}/lightning-terminal-cert"'';
      description = "Lightning Terminal TLS certificate path.";
    };
    tor = nbLib.tor;
    torHttpTunnelPort = mkOption {
      type = types.port;
      default = 9080;
      description = ''
        Port on the Tor client address for the HTTP CONNECT tunnel used by
        Lightning Terminal's outgoing gRPC and HTTP connections (including
        Lightning Node Connect mailbox sessions, Loop, Pool, and Autopilot)
        when {option}`tor.proxy` is enabled.
      '';
    };
  };

  cfg = config.services.lightning-terminal;
  nbLib = config.nix-bitcoin.lib;
  secretsDir = config.nix-bitcoin.secretsDir;
  runAsUser = config.nix-bitcoin.runAsUserCmd;
  bitcoind = config.services.bitcoind;
  lnd = config.services.lnd;

  litNetwork = nbLib.networkName {};
  usesBitcoind = cfg.faraday.enable && cfg.faraday.connectBitcoin;

  stripBrackets = s: removePrefix "[" (removeSuffix "]" s);
  ipv4Octet = "([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])";
  isIPv4 = s: builtins.match "${ipv4Octet}(\\.${ipv4Octet}){3}" s != null;
  isHextet = s: builtins.match "[0-9A-Fa-f]{1,4}" s != null;
  isIPv6 = s: let
    parts = splitString "::" s;
    left = if head parts == "" then [] else splitString ":" (head parts);
    right = if elemAt parts 1 == "" then [] else splitString ":" (elemAt parts 1);
    groups = splitString ":" s;
    checkTail = gs: maxGroups:
      if gs != [] && hasInfix "." (last gs) then
        all isHextet (init gs) && isIPv4 (last gs) && length left + length gs <= maxGroups - 1
      else
        all isHextet gs && length left + length gs <= maxGroups;
  in
    if length parts == 1 then
      (length groups == 8 && all isHextet groups)
      || (length groups == 7 && all isHextet (init groups) && isIPv4 (last groups))
    else
      length parts == 2
      && !(head parts != "" && hasSuffix ":" (head parts))
      && !(elemAt parts 1 != "" && hasPrefix ":" (elemAt parts 1))
      && all isHextet left
      && checkTail right 7;
  validBareHost = s: isIPv4 s || isIPv6 s;
  formatEndpoint = host: port: "${if hasInfix ":" host then "[${host}]" else host}:${toString port}";
  # go-flags unquotes double-quoted INI values with strconv.Unquote, preserving
  # spaces and comment characters without line splitting.
  iniStr = builtins.toJSON;

  bareHost = cfg.address;
  listenEndpoint = formatEndpoint bareHost cfg.port;
  dialHost = nbLib.address bareHost;
  dialEndpoint = formatEndpoint dialHost cfg.port;

  lndRpcHost = stripBrackets lnd.rpcAddress;
  lndDialHost = nbLib.address lndRpcHost;

  bitcoindDialHost = nbLib.address (stripBrackets bitcoind.rpc.address);
  bitcoindRpcEndpoint = formatEndpoint bitcoindDialHost bitcoind.rpc.port;

  torAddr = config.services.tor.client.socksListenAddress.addr;
  rawTorHost = if torAddr != null then stripBrackets torAddr else "";
  torDialHost =
    if elem rawTorHost [ "" "0.0.0.0" "::" ] then
      (if config.nix-bitcoin.netns-isolation.enable
       then config.nix-bitcoin.netns-isolation.bridgeIp
       else if rawTorHost == "::" then "::1" else "127.0.0.1")
    else
      nbLib.address rawTorHost;
  torTunnelBindAddr = if hasInfix ":" torDialHost then "[${torDialHost}]" else torDialHost;
  torHttpProxy = formatEndpoint torDialHost cfg.torHttpTunnelPort;

  startLightningTerminal = {
    serviceConfig.ExecStartPost = mkAfter [
      "-+${config.systemd.package}/bin/systemctl start --no-block --job-mode=ignore-requirements lightning-terminal.service"
    ];
  };

  # litd bakes super macaroons for LNC sessions and accounts via lnd.BakeMacaroon,
  # registers its RPC middleware via RegisterRPCMiddleware, derives macaroon store
  # keys via Signer.DeriveKey, and proxies lnd RPCs for UI/LNC/subservers.
  # Give it a dedicated root key in lnd-macaroons.nix so disabling
  # lightning-terminal revokes the macaroon automatically.
  lndPermissions = concatMapStringsSep ",\n" builtins.toJSON [
    { entity = "address"; action = "read"; }
    { entity = "address"; action = "write"; }
    { entity = "info"; action = "read"; }
    { entity = "info"; action = "write"; }
    { entity = "invoices"; action = "read"; }
    { entity = "invoices"; action = "write"; }
    { entity = "macaroon"; action = "generate"; }
    { entity = "macaroon"; action = "read"; }
    { entity = "macaroon"; action = "write"; }
    { entity = "message"; action = "read"; }
    { entity = "message"; action = "write"; }
    { entity = "offchain"; action = "read"; }
    { entity = "offchain"; action = "write"; }
    { entity = "onchain"; action = "read"; }
    { entity = "onchain"; action = "write"; }
    { entity = "peers"; action = "read"; }
    { entity = "peers"; action = "write"; }
    { entity = "signer"; action = "generate"; }
    { entity = "signer"; action = "read"; }
  ];

  # Note on Tor proxying: when `tor.proxy` is enabled, `HTTPS_PROXY` and
  # `HTTP_PROXY` point at Tor's `HTTPTunnelPort` (`IsolateDestAddr = true`).
  # Go's `google.golang.org/grpc` and `net/http` route outgoing LNC mailbox,
  # Loop, Pool, and Autopilot connections through `HTTPS_PROXY` automatically.
  # Do not also set `loop.server.proxy`, `pool.proxy`, or `autopilot.proxy`:
  # those clients pass `grpc.WithContextDialer(tor.Dial)` without
  # `grpc.WithNoProxy()`, which would rewrite the dial target to the local
  # `HTTPTunnelPort` address and ask Tor's SOCKS5 port to connect to localhost.
  configFile = pkgs.writeText "lit.conf" ''
    lit-dir=${iniStr (toString cfg.dataDir)}
    network=${litNetwork}
    httpslisten=${iniStr listenEndpoint}
    tlscertpath=${iniStr (toString cfg.certPath)}
    tlskeypath=${iniStr "${secretsDir}/lightning-terminal-key"}
    uipassword_file=${iniStr "${secretsDir}/lightning-terminal-password"}
    macaroonpath=${iniStr "${cfg.networkDir}/lit.macaroon"}

    lnd-mode=remote
    remote.lit-logging.file.disable=true
    remote.lit-logging.console.no-timestamps=true
    remote.lnd.rpcserver=${iniStr lnd.rpcEndpoint}
    remote.lnd.macaroonpath="/run/lightning-terminal/lnd.macaroon"
    remote.lnd.tlscertpath=${iniStr (toString lnd.certPath)}

    autopilot.disable=${boolToString (!cfg.autopilot.enable)}

    faraday-mode=${if cfg.faraday.enable then "integrated" else "disable"}
    ${optionalString cfg.faraday.enable ''
      faraday.faradaydir=${iniStr "${cfg.dataDir}/faraday"}
      faraday.logging.file.disable=true
      faraday.logging.console.no-timestamps=true
      faraday.connect_bitcoin=${boolToString cfg.faraday.connectBitcoin}
      ${optionalString cfg.faraday.connectBitcoin ''
        faraday.bitcoin.host=${iniStr bitcoindRpcEndpoint}
        faraday.bitcoin.user=${iniStr bitcoind.rpc.users.public.name}
        faraday.bitcoin.passwordfile=${iniStr "${secretsDir}/bitcoin-rpcpassword-public"}
        faraday.bitcoin.httppostmode=true
        faraday.bitcoin.usetls=false
      ''}
    ''}

    loop-mode=${if cfg.loop.enable then "integrated" else "disable"}
    ${optionalString cfg.loop.enable ''
      loop.loopdir=${iniStr "${cfg.dataDir}/loop"}
      loop.logging.file.disable=true
      loop.logging.console.no-timestamps=true
    ''}

    pool-mode=${if cfg.pool.enable then "integrated" else "disable"}
    ${optionalString cfg.pool.enable ''
      pool.basedir=${iniStr "${cfg.dataDir}/pool"}
      pool.logging.file.disable=true
      pool.logging.console.no-timestamps=true
    ''}

    taproot-assets-mode=${if cfg.taproot-assets.enable then "integrated" else "disable"}
    ${optionalString cfg.taproot-assets.enable ''
      taproot-assets.tapddir=${iniStr "${cfg.dataDir}/tapd"}
      taproot-assets.logging.file.disable=true
      taproot-assets.logging.console.no-timestamps=true
    ''}

    ${cfg.extraConfig}
  '';
in {
  inherit options;

  config = mkIf cfg.enable {
    warnings = optional (cfg.extraConfig != "")
      (nbLib.extraConfigWarning "services.lightning-terminal.extraConfig");

    assertions = [
      { assertion = cfg.port != 0;
        message = "services.lightning-terminal.port must not be 0.";
      }
      { assertion = validBareHost cfg.address;
        message = ''
          Invalid services.lightning-terminal.address ${builtins.toJSON cfg.address}.
          Use a numeric IPv4 or IPv6 address without a zone ID (bare or in brackets).
        '';
      }
      { assertion = !cfg.tor.proxy || cfg.torHttpTunnelPort != 0;
        message = "services.lightning-terminal.torHttpTunnelPort must not be 0 when tor.proxy is enabled.";
      }
      { assertion = !usesBitcoind || (bitcoind.txindex && bitcoind.prune == 0);
        message = "services.lightning-terminal.faraday.connectBitcoin requires services.bitcoind.txindex and does not support bitcoind pruning.";
      }
      { assertion = !cfg.loop.enable || litNetwork != "regtest" || hasInfix "loop.server.host" cfg.extraConfig;
        message = "services.lightning-terminal.loop cannot run on regtest without a custom loop.server.host in services.lightning-terminal.extraConfig.";
      }
      { assertion = !cfg.pool.enable || elem litNetwork [ "mainnet" "testnet" ] || hasInfix "pool.auctionserver" cfg.extraConfig;
        message = "services.lightning-terminal.pool requires mainnet or testnet unless a custom pool.auctionserver is set in services.lightning-terminal.extraConfig.";
      }
      { assertion = !cfg.autopilot.enable || litNetwork != "regtest" || hasInfix "autopilot.address" cfg.extraConfig;
        message = "services.lightning-terminal.autopilot cannot run on regtest without a custom autopilot.address in services.lightning-terminal.extraConfig.";
      }
    ];

    services.lnd = {
      enable = true;
      rpcMiddleware.enable = true;
      macaroons.lightning-terminal = {
        inherit (cfg) user;
        permissions = lndPermissions;
      };
    };

    services.bitcoind.txindex = mkIf usesBitcoind true;

    services.tor = mkIf cfg.tor.proxy {
      enable = true;
      client.enable = true;
      settings.HTTPTunnelPort = [{
        addr = torTunnelBindAddr;
        port = cfg.torHttpTunnelPort;
        IsolateDestAddr = true;
      }];
    };
    networking.firewall.interfaces.nb-br.allowedTCPPorts =
      mkIf (cfg.tor.proxy && config.nix-bitcoin.netns-isolation.enable) [
        cfg.torHttpTunnelPort
      ];

    environment.systemPackages = [ cfg.package (hiPrio cfg.cli) ];

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 ${cfg.user} ${cfg.group} - -"
    ];

    services.lightning-terminal.certificate.extraIPs =
      [ "::1" ] ++ optional (!elem bareHost [ "127.0.0.1" "0.0.0.0" "::1" "::" ]) bareHost;

    systemd.services.lightning-terminal = {
      wantedBy = [ "multi-user.target" ];
      bindsTo = [ "lnd.service" ] ++ optional usesBitcoind "bitcoind.service";
      after = [ "lnd.service" "nix-bitcoin-secrets.target" ]
        ++ optional usesBitcoind "bitcoind.service"
        ++ optional cfg.tor.proxy "tor.service";
      wants = [ "nix-bitcoin-secrets.target" ] ++ optional cfg.tor.proxy "tor.service";
      restartTriggers = optional config.nix-bitcoin.generateSecrets (nbLib.mkCertExtraAltNames cfg.certificate);
      environment = {
        # See modules/lnd.nix: avoid opening MPTCP listeners in Go >= 1.24.
        GODEBUG = "multipathtcp=0";
      } // optionalAttrs cfg.tor.proxy {
        HTTPS_PROXY = "http://${torHttpProxy}";
        HTTP_PROXY = "http://${torHttpProxy}";
        # Go's golang.org/x/net/http/httpproxy matches bare IPv6 literals (not
        # bracketed ones) when no port is attached. Include dialHost so litd's
        # internal gRPC-gateway never routes local self-connections to Tor.
        NO_PROXY = concatStringsSep "," (unique (
          [ "127.0.0.1" "::1" "localhost" bareHost dialHost lndRpcHost lndDialHost ]
          ++ optional usesBitcoind bitcoindDialHost
        ));
      };
      preStart = ''
        umask 077
        # lnd owns /run/lnd. Copy the macaroon without following symlinks so a
        # substituted link cannot make litd send a lightning-terminal secret to lnd.
        dd if=/run/lnd/lightning-terminal.macaroon of=/run/lightning-terminal/lnd.macaroon \
          iflag=nofollow,fullblock bs=65536 count=1 status=none
        test -s /run/lightning-terminal/lnd.macaroon
      '';
      serviceConfig = nbLib.defaultHardening // {
        ExecStart = "${cfg.package}/bin/litd --configfile=${configFile}";
        User = cfg.user;
        Group = cfg.group;
        RuntimeDirectory = "lightning-terminal";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = cfg.dataDir;
        ReadWritePaths = [ cfg.dataDir ];
        UMask = "0077";
        UnsetEnvironment = [ "https_proxy" "http_proxy" "no_proxy" "ALL_PROXY" "all_proxy" ]
          ++ optionals (!cfg.tor.proxy) [ "HTTPS_PROXY" "HTTP_PROXY" "NO_PROXY" ];
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStopSec = "5min";
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
    };

    # Like RTL: wantedBy on lnd would restart lnd on a clean STOPPING=1 exit,
    # and binding to bitcoind requires starting again when bitcoind restarts.
    systemd.services.lnd = startLightningTerminal;
    systemd.services.bitcoind = mkIf usesBitcoind startLightningTerminal;

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      extraGroups = optional usesBitcoind "bitcoinrpc-public";
    };
    users.groups.${cfg.group} = {};
    nix-bitcoin.operator.allowRunAsUsers = [ cfg.user ];

    nix-bitcoin.secrets = {
      lightning-terminal-password = {
        inherit (cfg) user group;
        permissions = "400";
      };
      lightning-terminal-key = {
        inherit (cfg) user group;
        permissions = "400";
      };
      lightning-terminal-cert = {
        inherit (cfg) user group;
        permissions = "444";
      };
    };
    nix-bitcoin.generateSecretsCmds.lightning-terminal = ''
      makePasswordSecret lightning-terminal-password
      makeCert lightning-terminal '${nbLib.mkCertExtraAltNames cfg.certificate}'
    '';
  };
}
