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
    url = mkOption {
      type = types.str;
      example = "https://mint.example.org";
      description = "Public URL of the mint, as used by Cashu wallets.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/cdk-mintd";
      description = "Persistent mint database, configuration state and optional BDK wallet.";
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
        Nix store. The module manages the listener, URL, signing seed, SQLite
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

  configFile = toml.generate "cdk-mintd.toml" (recursiveUpdate
    # Inactive backends must not retain settings, particularly secret references.
    (removeAttrs cfg.settings [ "database" "signatory" "lnd" "cln" "bdk" ] // {
      info = removeAttrs (cfg.settings.info or {}) [ "mnemonic" ];
    }) ({
      info = {
        inherit (cfg) url;
        listen_host = cfg.address;
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
        address = "https://${nbLib.addressWithPort lnd.rpcAddress lnd.rpcPort}";
        cert_file = lnd.certPath;
        macaroon_file = "/run/lnd/cdk-mintd.macaroon";
      };
    } else {
      cln = (cfg.settings.cln or {}) // { rpc_path = "${cln.networkDir}/lightning-rpc"; };
    }) // optionalAttrs cfg.onchain.enable {
      bdk = (cfg.settings.bdk or {}) // {
        mnemonic = "file:${cfg.onchain.mnemonicFile}";
        network = bitcoind.network;
        chain_source_type = "bitcoinrpc";
        bitcoind_rpc_host = nbLib.address bitcoind.rpc.address;
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
    ];

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

    systemd.tmpfiles.rules = [ "d '${cfg.dataDir}' 0700 ${cfg.user} ${cfg.group} - -" ];
    systemd.services.cdk-mintd = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "${cfg.backend}.service" ] ++ optional cfg.onchain.enable "bitcoind.service";
      after = [ "${cfg.backend}.service" "nix-bitcoin-secrets.target" ]
        ++ optional cfg.onchain.enable "bitcoind.service";
      preStart = ''
        umask 077
        ${optionalString cfg.onchain.enable ''
          # CDK's file references preserve newlines; Core's RPC password doesn't.
          password=$(cat ${secretsDir}/bitcoin-rpcpassword-public)
          printf '%s' "$password" > /run/cdk-mintd/bitcoin-rpcpassword
        ''}
        # CDK >= 0.18 reads its configuration from the database. Remember which
        # Nix document was imported so a restart doesn't reapply it or discard
        # the pending first-wallet creation permission after a failed start.
        if [[ $(readlink nix-config || true) != ${configFile} ]]; then
          if ${cli} config show > /dev/null; then
            ${cli} config apply --file ${configFile} \
              ${optionalString (cfg.onchain.enable && cfg.onchain.allowNewWallet) "--allow-new-bdk-wallet"}
          else
            # CDK refuses this for a DB with existing mint/keyset state.
            ${cli} config init --new-mint --file ${configFile}
          fi
          ln -sfn ${configFile} nix-config
        fi
      '';
      serviceConfig = nbLib.defaultHardening // {
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
    # Like RTL: wantedBy on lnd would restart it on a clean STOPPING=1 exit.
    systemd.services.${cfg.backend}.serviceConfig.ExecStartPost = [
      "-+${config.systemd.package}/bin/systemctl start --no-block cdk-mintd.service"
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = optional (!isLnd) cln.group ++ optional cfg.onchain.enable "bitcoinrpc-public";
    };
    users.groups.${cfg.group} = {};

    nix-bitcoin.secrets = {
      cdk-mintd-seed = mkIf defaultSeed { user = cfg.user; };
      cdk-mintd-bdk-mnemonic = mkIf (cfg.onchain.enable && defaultMnemonic) { user = cfg.user; };
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
