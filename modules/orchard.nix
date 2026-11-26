{ config, lib, pkgs, ... }:

with lib;
let
  options.services.orchard = {
    enable = mkEnableOption "Orchard, a web dashboard for the local CDK Cashu mint";
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "HTTP listen address. Use an SSH tunnel, onion service or HTTPS reverse proxy for remote access.";
    };
    port = mkOption {
      type = types.port;
      default = 3321;
      description = "HTTP listen port.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/orchard";
      description = "Orchard's user database, settings encryption key and runtime configuration. Keep these together when backing up.";
    };
    setupKeyFile = mkOption {
      type = types.str;
      default = "${secretsDir}/orchard-setup-key";
      defaultText = "\${config.nix-bitcoin.secretsDir}/orchard-setup-key";
      description = ''
        Absolute path to the secret authorizing creation of the first admin
        account. The default is generated when secret generation is enabled.
        A custom file must be readable by the service user. Use a string path
        so Nix does not copy the secret to the store.
      '';
    };
    mintRpcPort = mkOption {
      type = types.port;
      default = 8086;
      description = ''
        CDK management RPC port. The module enables mutual TLS and binds it to
        loopback, or the mint's private address with network namespace isolation.
        Orchard can change mint metadata, fees and keysets through this API.
        Quote payment overrides remain disabled. Nix configuration changes can
        replace changes made in Orchard.
      '';
    };
    user = mkOption {
      type = types.str;
      default = "orchard";
      description = "User running Orchard.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      defaultText = "config.services.orchard.user";
      description = "Group running Orchard.";
    };
    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.cashu-orchard;
      defaultText = "config.nix-bitcoin.pkgs.cashu-orchard";
      description = "Package providing the cashu-orchard binary.";
    };
    tor.enforce = nbLib.tor.enforce;
  };

  cfg = config.services.orchard;
  mint = config.services.cdk-mintd;
  nbLib = config.nix-bitcoin.lib;
  secretsDir = config.nix-bitcoin.secretsDir;
  netns = config.nix-bitcoin.netns-isolation;
  rpcAddress = if netns.enable then netns.netns.cdk-mintd.address else "127.0.0.1";
  rpcTlsDir = "/run/cdk-mintd/orchard-rpc";
  mintHost = let
    address = nbLib.address (removeSuffix "]" (removePrefix "[" mint.address));
  in if hasInfix ":" address then "[${address}]" else address;
  defaultSetupKey = cfg.setupKeyFile == "${secretsDir}/orchard-setup-key";
  database = "${mint.dataDir}/cdk-mintd.sqlite";
  orchardPath = toString (/. + cfg.dataDir);
  mintPath = toString (/. + mint.dataDir);
  # Membership disappears when Orchard is disabled. Only these three files,
  # never the mint's seed, BDK wallet or backend credentials, receive a read ACL.
  databaseGroup = "orchard-mint";
  openssl = "${pkgs.openssl}/bin/openssl";
  # The daemon keeps the WAL open. Reapply file ACLs after every restart,
  # including backup snapshots. No directory default ACL is installed.
  grantDatabaseAccess = nbLib.script "orchard-database-access-as-mint" ''
    for _attempt in $(seq 1 60); do
      if [[ -f ${escapeShellArg "${database}-wal"} && -f ${escapeShellArg "${database}-shm"} ]]; then
        ${pkgs.acl}/bin/setfacl -P -m g:${databaseGroup}:--x ${escapeShellArg mint.dataDir}
        ${pkgs.acl}/bin/setfacl -P -m g:${databaseGroup}:r-- \
          ${escapeShellArg database} ${escapeShellArg "${database}-wal"} ${escapeShellArg "${database}-shm"}
        exit 0
      fi
      sleep 1
    done
    echo "CDK SQLite WAL did not become available for Orchard" >&2
    exit 1
  '';
in {
  inherit options;

  config = mkIf cfg.enable {
    assertions = [
      { assertion = hasPrefix "/" cfg.setupKeyFile;
        message = "orchard.setupKeyFile must be an absolute path.";
      }
      { assertion = cfg.user != mint.user && cfg.group != mint.group;
        message = "orchard must use a different user and group from cdk-mintd.";
      }
      { assertion = orchardPath != "/" && orchardPath != mintPath
          && !hasPrefix "${orchardPath}/" mintPath && !hasPrefix "${mintPath}/" orchardPath;
        message = "orchard and cdk-mintd data directories must not overlap.";
      }
      { assertion = cfg.port != 0 && cfg.mintRpcPort != 0;
        message = "orchard ports must not be zero.";
      }
    ];

    services.cdk-mintd = {
      enable = true;
      settings.mint_management_rpc = {
        enabled = true;
        address = rpcAddress;
        port = cfg.mintRpcPort;
        tls_dir = rpcTlsDir;
        allow_insecure = false;
        allow_mint_quote_payment_override = false;
      };
    };

    systemd.tmpfiles.rules = [ "d '${cfg.dataDir}' 0700 ${cfg.user} ${cfg.group} - -" ];
    systemd.services.orchard = {
      wantedBy = [ "multi-user.target" ];
      bindsTo = [ "cdk-mintd.service" ];
      after = [ "cdk-mintd.service" "nix-bitcoin-secrets.target" ];
      environment = {
        SERVER_HOST = cfg.address;
        SERVER_PORT = toString cfg.port;
        DATABASE_DIR = cfg.dataDir;
        MINT_TYPE = "cdk";
        MINT_API = "http://${mintHost}:${toString mint.port}";
        MINT_DATABASE = database;
        MINT_RPC_HOST = rpcAddress;
        MINT_RPC_PORT = toString cfg.mintRpcPort;
        MINT_RPC_MTLS = "true";
        MINT_RPC_KEY = "${secretsDir}/orchard-rpc-client-key";
        MINT_RPC_CERT = "${secretsDir}/orchard-rpc-client-cert";
        MINT_RPC_CA = "${secretsDir}/orchard-rpc-ca-cert";
      };
      script = ''
        SETUP_KEY=$(cat ${escapeShellArg cfg.setupKeyFile})
        export SETUP_KEY
        test -n "$SETUP_KEY"
        exec ${lib.getExe cfg.package}
      '';
      serviceConfig = nbLib.defaultHardening // nbLib.nodejs // {
        User = cfg.user;
        Group = cfg.group;
        SupplementaryGroups = [ databaseGroup ];
        WorkingDirectory = cfg.dataDir;
        UMask = "0077";
        ReadWritePaths = [ cfg.dataDir ];
        Restart = "on-failure";
        RestartSec = "10s";
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
    };

    systemd.services.cdk-mintd = {
      preStart = mkBefore ''
        mkdir -p ${rpcTlsDir}
        ln -sfn ${secretsDir}/orchard-rpc-ca-cert ${rpcTlsDir}/ca.pem
        ln -sfn ${secretsDir}/orchard-rpc-server-cert ${rpcTlsDir}/server.pem
        ln -sfn ${secretsDir}/orchard-rpc-server-key ${rpcTlsDir}/server.key
      '';
      serviceConfig.ExecStartPost = mkAfter [
        # PrivateUsers maps only the mint's uid/gid, so an ACL naming Orchard's
        # group cannot be set inside that namespace. Leave it with `+`, then
        # immediately drop to the mint user before accessing mint-owned paths.
        (nbLib.rootScript "orchard-database-access" ''
          exec ${pkgs.util-linux}/bin/runuser -u ${escapeShellArg mint.user} -- ${grantDatabaseAccess}
        '')
        "-+${config.systemd.package}/bin/systemctl start --no-block --job-mode=ignore-requirements orchard.service"
      ];
    };

    users.users.${cfg.user} = { isSystemUser = true; group = cfg.group; };
    users.groups.${cfg.group} = {};
    users.groups.${databaseGroup} = {};

    nix-bitcoin.secrets = {
      orchard-setup-key = mkIf defaultSetupKey { inherit (cfg) user group; };
      orchard-rpc-ca-key = { user = "root"; };
      orchard-rpc-ca-cert = { user = "root"; permissions = "0444"; };
      orchard-rpc-server-key = { inherit (mint) user group; };
      orchard-rpc-server-cert = { inherit (mint) user group; };
      orchard-rpc-client-key = { inherit (cfg) user group; };
      orchard-rpc-client-cert = { inherit (cfg) user group; };
    };
    nix-bitcoin.generateSecretsCmds.orchard = ''
      ${optionalString defaultSetupKey "makePasswordSecret orchard-setup-key"}
      makeCert orchard-rpc-ca
      # Issue separate leaf certificates: neither service receives the CA key
      # or the other's private key. Regenerate leaves when their address changes
      # or expiry approaches, preserving the private keys.
      for role in server client; do
        name=orchard-rpc-$role
        if isAbsent "$name-key"; then
          writeSecret "$name-key" ${openssl} genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1
        else
          checkKey "$name-key" "Orchard's management RPC authentication"
        fi
        if [[ $role == server ]]; then
          extensions='subjectAltName=IP:${rpcAddress}'
          usage=serverAuth
        else
          extensions='subjectAltName=DNS:orchard'
          usage=clientAuth
        fi
        if [[ $name-key -nt $name-cert || orchard-rpc-ca-cert -nt $name-cert ]] ||
           [[ $(cat "$name-cert-alt-names" 2>/dev/null) != "$extensions" ]] ||
           ! ${openssl} x509 -checkend 2592000 -noout -in "$name-cert" 2>/dev/null; then
          tmpDir=$(mktemp -d)
          ${openssl} req -new -key "$name-key" -subj /CN=localhost -out "$tmpDir/request"
          printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
            "extendedKeyUsage=$usage" "$extensions" > "$tmpDir/extensions"
          writeSecret "$name-cert" ${openssl} x509 -req -in "$tmpDir/request" \
            -CA orchard-rpc-ca-cert -CAkey orchard-rpc-ca-key \
            -set_serial "0x$(${openssl} rand -hex 16)" -days 3650 -sha256 -extfile "$tmpDir/extensions"
          writeSecret "$name-cert-alt-names" echo "$extensions"
          rm -rf "$tmpDir"
        fi
      done
    '';
  };
}
