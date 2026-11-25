{ config, lib, pkgs, ... }:

with lib;
let
  options.services.cdk-mintd = {
    enable = mkEnableOption "cdk-mintd, a Cashu ecash mint";
    backend = mkOption {
      type = types.enum [ "lnd" "clightning" ];
      default = "lnd";
      description = ''
        Local Lightning backend, enabled automatically. LND uses a restricted
        macaroon; Core Lightning uses its Unix RPC socket, with full RPC access.
      '';
    };
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "HTTP listen address. Use a reverse proxy for public HTTPS access.";
    };
    port = mkOption {
      type = types.port;
      default = 8085;
      description = "HTTP listen port.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/cdk-mintd";
      description = "Persistent mint database, configuration state and optional BDK wallet.";
    };
    allowNewMint = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Allow initializing an empty database after a mint has already been
        initialized on this node. Only use this to deliberately replace a mint
        with a new signing seed, never to recover missing mint data. Reusing a
        seed without its spent-proof database can allow double spending. Set
        back to false after initialization. The first mint needs no override.
      '';
    };
    seedFile = mkOption {
      type = types.str;
      default = "${secretsDir}/cdk-mintd-seed";
      defaultText = "\${config.nix-bitcoin.secretsDir}/cdk-mintd-seed";
      description = ''
        Absolute path to the mint's raw signing seed, read byte-for-byte (not
        hex-decoded). The default is generated with 256 bits of entropy when
        secret generation is enabled. Preserve its exact contents, including
        whitespace. A custom file must be readable by the service user.
      '';
    };
    onchain = {
      enable = mkEnableOption "on-chain minting and melting using a separate BDK wallet and local Bitcoin Core";
      mnemonicFile = mkOption {
        type = types.str;
        default = "${secretsDir}/cdk-mintd-bdk-mnemonic";
        defaultText = "\${config.nix-bitcoin.secretsDir}/cdk-mintd-bdk-mnemonic";
        description = ''
          Absolute path to the BDK wallet's BIP39 mnemonic. The default is
          generated when secret generation is enabled. A custom file must be
          readable by the service user. Keep it separate from the mint seed.
        '';
      };
      allowNewWallet = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Allow a configuration change to create a missing BDK wallet database.
          Needed when adding on-chain support to an existing mint, but not for
          a new mint. Set back to false after a successful start. For recovery,
          restore the original wallet database instead whenever possible; see
          the CDK mint service guide before using mnemonic-only recovery.
        '';
      };
    };
    settings = mkOption {
      type = toml.type;
      default = {};
      example = { mint_info.name = "My mint"; info.input_fee_ppk = 100; };
      description = ''
        Additional CDK TOML settings, such as mint metadata, payment limits and
        fees. See the upstream cdk-mintd example.config.toml for the packaged
        version. Never put secret values here: this document is public in the
        Nix store. The module manages the listener, signing seed, SQLite
        database, backend selection and backend connection settings. Those
        values take precedence over this option. Remote signing is disabled.
        Nix configuration changes replace the stored CDK configuration before
        startup; changes made through CDK's management tools are not declarative.
      '';
    };
    user = mkOption {
      type = types.str;
      default = "cdk-mintd";
      description = "User running the mint.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      defaultText = "config.services.cdk-mintd.user";
      description = "Group running the mint.";
    };
    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.cashu-cdk;
      defaultText = "config.nix-bitcoin.pkgs.cashu-cdk";
      description = "Package providing the cdk-mintd binary.";
    };
    tor.enforce = nbLib.tor.enforce;
  };

  cfg = config.services.cdk-mintd;
  nbLib = config.nix-bitcoin.lib;
  secretsDir = config.nix-bitcoin.secretsDir;
  bitcoind = config.services.bitcoind;
  lnd = config.services.lnd;
  cln = config.services.clightning;
  isLnd = cfg.backend == "lnd";
  toml = pkgs.formats.toml {};
  mintd = "${cfg.package}/bin/cdk-mintd";
  cli = "${mintd} --work-dir ${escapeShellArg cfg.dataDir}";
  defaultSeed = cfg.seedFile == "${secretsDir}/cdk-mintd-seed";
  defaultMnemonic = cfg.onchain.mnemonicFile == "${secretsDir}/cdk-mintd-bdk-mnemonic";
  # Kept outside dataDir, owned by root and included in the node's backups.
  stateDir = "/var/lib/nixos/cdk-mintd";
  dataPath = toString (/. + cfg.dataDir);
  bracketIPv6 = addr: if hasInfix ":" addr && !hasPrefix "[" addr then "[${addr}]" else addr;
  connectAddress = addr: bracketIPv6 (nbLib.address (removeSuffix "]" (removePrefix "[" addr)));
  configState = pkgs.writeText "cdk-mintd-config-state.json" (builtins.toJSON {
    config = configFile;
    allowNewWallet = cfg.onchain.enable && cfg.onchain.allowNewWallet;
  });

  configFile = toml.generate "cdk-mintd.toml" (recursiveUpdate
    # Inactive backends must not retain settings, particularly secret references.
    (removeAttrs cfg.settings [ "database" "signatory" "lnd" "cln" "bdk" ] // {
      info = removeAttrs (cfg.settings.info or {}) [ "mnemonic" ];
    }) ({
      info = {
        listen_host = bracketIPv6 cfg.address;
        listen_port = cfg.port;
        seed = "file:${cfg.seedFile}";
      };
      database.engine = "sqlite";
      signatory.enabled = false;
      payment_backend = (cfg.settings.payment_backend or {}) // {
        backend = if isLnd then "lnd" else "cln";
        unit = "sat";
      };
      onchain.onchain_backend = if cfg.onchain.enable then "bdk" else "none";
    } // (if isLnd then {
      lnd = (cfg.settings.lnd or {}) // {
        address = "https://${lnd.rpcEndpoint}";
        cert_file = lnd.certPath;
        macaroon_file = "/run/cdk-mintd/lnd.macaroon";
      };
    } else {
      cln = (cfg.settings.cln or {}) // { rpc_path = "${cln.networkDir}/lightning-rpc"; };
    }) // optionalAttrs cfg.onchain.enable {
      bdk = (cfg.settings.bdk or {}) // {
        mnemonic = "file:${cfg.onchain.mnemonicFile}";
        network = bitcoind.network;
        chain_source_type = "bitcoinrpc";
        bitcoind_rpc_host = connectAddress bitcoind.rpc.address;
        bitcoind_rpc_port = bitcoind.rpc.port;
        bitcoind_rpc_user = bitcoind.rpc.users.public.name;
        bitcoind_rpc_password = "file:/run/cdk-mintd/bitcoin-rpcpassword";
      };
    }));

  # Every RPC called by cdk-lnd 0.18, including MPP and payment recovery.
  lndMethods = [
    "/lnrpc.Lightning/AddInvoice"
    "/lnrpc.Lightning/LookupInvoice"
    "/lnrpc.Lightning/SubscribeInvoices"
    "/lnrpc.Lightning/QueryRoutes"
    "/routerrpc.Router/SendPaymentV2"
    "/routerrpc.Router/SendToRouteV2"
    "/routerrpc.Router/TrackPaymentV2"
  ];
in {
  inherit options;

  config = mkIf cfg.enable {
    assertions = [
      { assertion = !cfg.onchain.enable || bitcoind.network != "testnet4";
        message = "cdk-mintd's BDK backend does not support testnet4.";
      }
      { assertion = !cfg.onchain.enable || bitcoind.prune == 0;
        message = "cdk-mintd's BDK Bitcoin RPC backend requires unpruned blocks for wallet scanning.";
      }
      { assertion = hasPrefix "/" cfg.seedFile && (!cfg.onchain.enable || hasPrefix "/" cfg.onchain.mnemonicFile);
        message = "cdk-mintd seedFile and onchain.mnemonicFile must be absolute paths.";
      }
      { assertion = dataPath != "/" && dataPath != stateDir
          && !hasPrefix "${dataPath}/" stateDir && !hasPrefix "${stateDir}/" dataPath;
        message = "cdk-mintd dataDir must not overlap ${stateDir}, which holds the root-owned initialization guard.";
      }
    ];

    services.cdk-mintd.settings.info.logging.output = mkDefault "stderr";
    services.lnd = mkIf isLnd {
      enable = true;
      macaroons.cdk-mintd = {
        inherit (cfg) user;
        permissions = concatMapStringsSep ","
          (method: builtins.toJSON { entity = "uri"; action = method; }) lndMethods;
      };
    };
    services.clightning.enable = mkIf (!isLnd) true;
    services.bitcoind.enable = mkIf cfg.onchain.enable true;

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 ${cfg.user} ${cfg.group} - -"
      "d /var/lib/nixos 0755 root root - -"
      "d ${stateDir} 0755 root root - -"
    ];
    systemd.services.cdk-mintd = {
      wantedBy = [ "multi-user.target" ];
      bindsTo = [ "${cfg.backend}.service" ] ++ optional cfg.onchain.enable "bitcoind.service";
      after = [ "${cfg.backend}.service" "nix-bitcoin-secrets.target" ]
        ++ optional cfg.onchain.enable "bitcoind.service";
      preStart = ''
        umask 077
        # Validate the guard and its parent before CDK can create a database.
        # In particular, ENOTDIR or a user-replaceable directory must never be
        # interpreted as a missing marker. Tmpfiles creates these for new mints.
        for dir in /var/lib/nixos ${stateDir}; do
          guardMode=$(stat -c %a "$dir")
          if [[ ! -d $dir || -L $dir || ! -r $dir || ! -x $dir ]] ||
             [[ $(stat -c %u "$dir") != 0 ]] ||
             (( (8#$guardMode & 8#022) != 0 )); then
            echo "Unsafe initialization guard directory $dir; refusing to start the mint. Restore a real, root-owned directory with mode 0755 and its original initialization marker." >&2
            exit 1
          fi
        done
        ${optionalString isLnd ''
          # lnd owns /run/lnd. Do not let a substituted symlink make CDK send
          # a mint secret to lnd as the macaroon header.
          dd if=/run/lnd/cdk-mintd.macaroon of=/run/cdk-mintd/lnd.macaroon \
            iflag=nofollow,fullblock bs=65536 count=1 status=none
          test -s /run/cdk-mintd/lnd.macaroon
        ''}
        ${optionalString cfg.onchain.enable ''
          # CDK's file references preserve newlines; Core's RPC password doesn't.
          password=$(cat ${secretsDir}/bitcoin-rpcpassword-public)
          printf '%s' "$password" > /run/cdk-mintd/bitcoin-rpcpassword
        ''}
        # CDK >= 0.18 reads its configuration from the database. Remember which
        # Nix document and wallet-creation flag were imported so a restart doesn't
        # reapply them or discard
        # the pending first-wallet creation permission after a failed start.
        # Always check the database, even if its config marker survived data loss.
        if ${cli} config show > /dev/null; then
          if [[ $(readlink nix-config || true) != ${configState} ]]; then
            ${cli} config apply --file ${configFile} \
              ${optionalString (cfg.onchain.enable && cfg.onchain.allowNewWallet) "--allow-new-bdk-wallet"}
          fi
        else
          ${optionalString (!cfg.allowNewMint) ''
            if [[ -e ${stateDir}/initialized || -L ${stateDir}/initialized ]]; then
              echo "Refusing to recreate an initialized mint. Restore its database and signing secrets; a seed alone cannot recover spent-proof state." >&2
              exit 1
            fi
          ''}
          # CDK also refuses this for a DB with existing mint/keyset state.
          ${cli} config init --new-mint --file ${configFile}
        fi
        ln -sfn ${configState} nix-config
      '';
      serviceConfig = nbLib.defaultHardening // {
        # Record initialization before the daemon can serve any payments. The
        # service user cannot remove this marker when its database is lost.
        ExecStartPre = mkAfter [ (nbLib.rootScript "cdk-mintd-record-initialization" ''
          touch ${stateDir}/initialized
        '') ];
        ExecStart = cli;
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        RuntimeDirectory = "cdk-mintd";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        ReadWritePaths = [ cfg.dataDir ];
        Restart = "on-failure";
        RestartSec = "10s";
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
    };
    # Like RTL: don't pull stopped dependencies back up from a backend hook.
    # BindsTo + After refuses the mint start if another dependency is inactive.
    # wantedBy on lnd would restart it on a clean STOPPING=1 exit.
    systemd.services.${cfg.backend}.serviceConfig.ExecStartPost = [
      "-+${config.systemd.package}/bin/systemctl start --no-block --job-mode=ignore-requirements cdk-mintd.service"
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = optional (!isLnd) cln.group ++ optional cfg.onchain.enable "bitcoinrpc-public";
    };
    users.groups.${cfg.group} = {};

    nix-bitcoin.secrets = {
      cdk-mintd-seed = mkIf defaultSeed { inherit (cfg) user group; };
      cdk-mintd-bdk-mnemonic = mkIf (cfg.onchain.enable && defaultMnemonic) { inherit (cfg) user group; };
    };
    nix-bitcoin.generateSecretsCmds.cdk-mintd = optionalString defaultSeed ''
      if isAbsent cdk-mintd-seed; then
        writeSecret cdk-mintd-seed ${pkgs.openssl}/bin/openssl rand -hex 32
      else
        checkKey cdk-mintd-seed "the mint signing identity"
      fi
    '' + optionalString (cfg.onchain.enable && defaultMnemonic) ''
      if isAbsent cdk-mintd-bdk-mnemonic; then
        writeSecret cdk-mintd-bdk-mnemonic \
          ${pkgs.python3.withPackages (ps: [ ps.mnemonic ])}/bin/python -c \
          'from mnemonic import Mnemonic; print(Mnemonic("english").generate(256))'
      else
        checkKey cdk-mintd-bdk-mnemonic "the mint on-chain wallet"
      fi
    '';
  };
}
