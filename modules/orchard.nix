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
  rpcTlsDir = "/run/orchard-rpc-tls";
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
    for _attempt in $(seq 1 600); do
      if [[ -f ${escapeShellArg "${database}-wal"} && -f ${escapeShellArg "${database}-shm"} ]]; then
        ${pkgs.acl}/bin/setfacl -P -m g:${databaseGroup}:--x ${escapeShellArg mint.dataDir}
        ${pkgs.acl}/bin/setfacl -P -m g:${databaseGroup}:r-- \
          ${escapeShellArg database} ${escapeShellArg "${database}-wal"} ${escapeShellArg "${database}-shm"}
        exit 0
      fi
      sleep 0.1
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
        tls_dir = "${rpcTlsDir}/server";
        allow_insecure = false;
        allow_mint_quote_payment_override = false;
      };
    };

    systemd.tmpfiles.rules = [ "d '${cfg.dataDir}' 0700 ${cfg.user} ${cfg.group} - -" ];

    # Ephemeral local-only mTLS credentials for the CDK management RPC.
    # Neither service persists or pins these certs, and the CA key is discarded
    # immediately after signing both leaf certificates.
    systemd.services.orchard-rpc-tls = {
      description = "Generate ephemeral mTLS certificates for Orchard CDK management RPC";
      before = [ "cdk-mintd.service" "orchard.service" ];
      script = ''
        set -euo pipefail
        tmpDir=$(mktemp -d)
        trap 'rm -rf "$tmpDir"' EXIT
        ${openssl} req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
          -keyout "$tmpDir/ca.key" -out "$tmpDir/ca.pem" \
          -days 3650 -sha256 -subj /CN=orchard-rpc-ca \
          -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
          -addext 'keyUsage=critical,keyCertSign'
        issue() {
          local role=$1 ext=$2 usage=$3
          ${openssl} genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "$tmpDir/$role.key"
          ${openssl} req -new -key "$tmpDir/$role.key" -subj /CN=localhost -out "$tmpDir/$role.csr"
          printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
            "extendedKeyUsage=$usage" "$ext" > "$tmpDir/$role.ext"
          ${openssl} x509 -req -in "$tmpDir/$role.csr" \
            -CA "$tmpDir/ca.pem" -CAkey "$tmpDir/ca.key" \
            -set_serial "0x$(${openssl} rand -hex 16)" -days 3650 -sha256 \
            -extfile "$tmpDir/$role.ext" -out "$tmpDir/$role.pem"
        }
        issue server 'subjectAltName=IP:${rpcAddress}' serverAuth
        issue client 'subjectAltName=DNS:orchard' clientAuth
        install -d -o ${escapeShellArg mint.user} -g ${escapeShellArg mint.group} -m 0700 ${rpcTlsDir}/server
        install -o ${escapeShellArg mint.user} -g ${escapeShellArg mint.group} -m 0400 \
          "$tmpDir/ca.pem" "$tmpDir/server.pem" "$tmpDir/server.key" ${rpcTlsDir}/server/
        install -d -o ${escapeShellArg cfg.user} -g ${escapeShellArg cfg.group} -m 0700 ${rpcTlsDir}/client
        install -o ${escapeShellArg cfg.user} -g ${escapeShellArg cfg.group} -m 0400 \
          "$tmpDir/ca.pem" "$tmpDir/client.pem" "$tmpDir/client.key" ${rpcTlsDir}/client/
      '';
      serviceConfig = nbLib.defaultHardening // {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "orchard-rpc-tls";
        RuntimeDirectoryMode = "0711";
        UMask = "0077";
        PrivateNetwork = true;
        RestrictAddressFamilies = "AF_UNIX";
        # Map real uids to assign server and client certs to their respective users.
        PrivateUsers = false;
        CapabilityBoundingSet = [ "CAP_CHOWN" "CAP_FOWNER" "CAP_DAC_OVERRIDE" ];
      };
    };

    systemd.services.orchard = {
      wantedBy = [ "multi-user.target" ];
      bindsTo = [ "cdk-mintd.service" ];
      requires = [ "orchard-rpc-tls.service" ];
      after = [ "cdk-mintd.service" "orchard-rpc-tls.service" "nix-bitcoin-secrets.target" ];
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
        MINT_RPC_KEY = "${rpcTlsDir}/client/client.key";
        MINT_RPC_CERT = "${rpcTlsDir}/client/client.pem";
        MINT_RPC_CA = "${rpcTlsDir}/client/ca.pem";
      };
      script = ''
        SETUP_KEY=$(cat ${escapeShellArg cfg.setupKeyFile})
        export SETUP_KEY
        test -n "$SETUP_KEY"
        exec ${lib.getExe cfg.package}
      '';
      serviceConfig = nbLib.defaultHardening // nbLib.nodejs // {
        SyslogIdentifier = "orchard";
        User = cfg.user;
        Group = cfg.group;
        SupplementaryGroups = [ databaseGroup ];
        UMask = "0077";
        ReadWritePaths = [ cfg.dataDir ];
        Restart = "on-failure";
        RestartSec = "10s";
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
    };

    systemd.services.cdk-mintd = {
      requires = [ "orchard-rpc-tls.service" ];
      after = [ "orchard-rpc-tls.service" ];
      serviceConfig.ExecStartPost = mkAfter [
        # PrivateUsers maps only the mint's uid/gid, so an ACL naming Orchard's
        # group cannot be set inside that namespace. Leave it with `+`, then
        # immediately drop to the mint user before accessing mint-owned paths.
        (nbLib.rootScript "orchard-database-access" ''
          exec ${pkgs.util-linux}/bin/setpriv --reuid=${escapeShellArg mint.user} \
            --regid=${escapeShellArg mint.group} --clear-groups -- ${grantDatabaseAccess}
        '')
        "-+${config.systemd.package}/bin/systemctl start --no-block --job-mode=ignore-requirements orchard.service"
      ];
    };

    users.users.${cfg.user} = { isSystemUser = true; group = cfg.group; };
    users.groups.${cfg.group} = {};
    users.groups.${databaseGroup} = {};

    nix-bitcoin.secrets = {
      orchard-setup-key = mkIf defaultSetupKey { inherit (cfg) user group; };
    };
    nix-bitcoin.generateSecretsCmds.orchard = optionalString defaultSetupKey ''
      makePasswordSecret orchard-setup-key
    '';
  };
}
