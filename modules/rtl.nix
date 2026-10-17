{ config, lib, pkgs, ... }:

with lib;
let
  options.services.rtl = {
    enable = mkEnableOption "Ride The Lightning, a web interface for lnd and clightning";
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "HTTP server address.";
    };
    port = mkOption {
      type = types.port;
      default = 3000;
      description = "HTTP server port.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/rtl";
      description = "The data directory for RTL.";
    };
    nodes = {
      clightning = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable the clightning node interface.";
        };
        extraConfig = mkOption {
          type = with types; attrsOf anything;
          default = {};
          example = {
            Settings.userPersona = "MERCHANT";
            Settings.logLevel = "DEBUG";
          };
          description = ''
            Extra clightning node configuration.
            See here for all available options:
            https://github.com/Ride-The-Lightning/RTL/blob/master/.github/docs/Application_configurations.md
          '';
        };
      };
      lnd = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable the lnd node interface.";
        };
        loop = mkOption {
          type = types.bool;
          default = false;
          description = "Enable swaps with lightning-loop.";
        };
        extraConfig = mkOption {
          type = with types; attrsOf anything;
          default = {};
          example = {
            Settings.userPersona = "MERCHANT";
            Settings.logLevel = "DEBUG";
          };
          description = ''
            Extra lnd node configuration.
            See here for all available options:
            https://github.com/Ride-The-Lightning/RTL/blob/master/.github/docs/Application_configurations.md
          '';
        };
      };
      reverseOrder = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Reverse the order of nodes shown in the UI.
          By default, clightning is shown before lnd.
        '';
      };
    };
    nightTheme = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the Night UI Theme.";
    };
    extraCurrency = mkOption {
      type = with types; nullOr str;
      default = null;
      example = "USD";
      description = ''
        Currency code (ISO 4217) of the extra currency used for displaying balances.
        When set, this option enables online currency rate fetching.
        Warning: Rate fetching requires outgoing clearnet connections, so option
        {option}`tor.enforce` is automatically disabled.
      '';
    };
    user = mkOption {
      type = types.str;
      default = "rtl";
      description = "The user as which to run RTL.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      description = "The group as which to run RTL.";
    };
    tor.enforce = nbLib.tor.enforce;
  };

  cfg = config.services.rtl;
  nbLib = config.nix-bitcoin.lib;
  nbPkgs = config.nix-bitcoin.pkgs;
  secretsDir = config.nix-bitcoin.secretsDir;
  runePath = "${cfg.dataDir}/clightning-admin-rune";

  runuser = "${pkgs.util-linux}/bin/runuser";

  # Shared by the root scripts that copy lnd/clightning credentials to RTL.
  # The source dirs are writable by the lnd/clightning user and `cfg.dataDir` is
  # writable by the rtl user, so any of them could place symlinks there.
  # So never access paths in these dirs as root:
  # - Read the source as the user that owns it (`runuser`), into "$tmpFile",
  #   a file in a fresh dir that only root can write to.
  # - Install the file to its destination as the rtl user.
  #   This only grants the rtl user rights it already has.
  #   `install --compare` doesn't rewrite unchanged files.
  installAsRtl = ''
    umask 077
    tmpDir=$(mktemp -d)
    trap 'rm -rf "$tmpDir"' EXIT
    # Let the rtl user access "$tmpFile" (owned by rtl, mode 600), but not list the dir
    chmod 711 "$tmpDir"
    tmpFile=$tmpDir/file
    installAsRtl() {
      chown ${cfg.user}:${cfg.group} "$tmpFile"
      ${runuser} -u ${cfg.user} -- install --compare -m 640 -D "$tmpFile" "$1"
    }
  '';

  inherit (nbLib) optionalAttr;

  node = { isLnd, index }: {
    inherit index;
    lnNode = "Node";
    lnImplementation = if isLnd then "LND" else "CLT";
    Authentication = {
      ${optionalAttr (isLnd && lndLoopEnabled) "swapMacaroonPath"} = "${lightning-loop.dataDir}/${bitcoind.network}";
      ${optionalAttr (isLnd) "macaroonPath"} = "${cfg.dataDir}/macaroons";
      ${optionalAttr (!isLnd) "runePath"} = runePath;
    };
    Settings = {
      userPersona = "OPERATOR";
      themeMode = if cfg.nightTheme then "NIGHT" else "DAY";
      themeColor = "PURPLE";
      ${optionalAttr isLnd "channelBackupPath"} = "${cfg.dataDir}/backup/lnd";
      logLevel = "INFO";
      fiatConversion = cfg.extraCurrency != null;
      ${optionalAttr (cfg.extraCurrency != null) "currencyUnit"} = cfg.extraCurrency;
      ${optionalAttr (isLnd && lndLoopEnabled) "swapServerUrl"} =
        "https://${nbLib.addressWithPort lightning-loop.restAddress lightning-loop.restPort}";
      lnServerUrl = "https://${
        if isLnd
        then nbLib.addressWithPort lnd.restAddress lnd.restPort
        else nbLib.addressWithPort clightning.plugins.clnrest.address clightning.plugins.clnrest.port
      }";
    };
  };

  nodes' =
    optional cfg.nodes.clightning.enable
      (recursiveUpdate (node { isLnd = false; index = 1; }) cfg.nodes.clightning.extraConfig) ++
    optional cfg.nodes.lnd.enable
      (recursiveUpdate (node { isLnd = true;  index = 2; }) cfg.nodes.lnd.extraConfig);

  nodes = if cfg.nodes.reverseOrder then reverseList nodes' else nodes';

  rtlConfig = {
    multiPass = "@multiPass@";
    host = cfg.address;
    port = cfg.port;
    SSO.rtlSSO = 0;
    inherit nodes;
  };

  configFile = builtins.toFile "config" (builtins.toJSON rtlConfig);

  inherit (config.services)
    bitcoind
    lnd
    clightning
    lightning-loop;

  lndLoopEnabled = cfg.nodes.lnd.enable && cfg.nodes.lnd.loop;
in {
  inherit options;

  config = mkIf cfg.enable {
    assertions = [
      { assertion = cfg.nodes.clightning.enable || cfg.nodes.lnd.enable;
        message = ''
          RTL: At least one of `nodes.lnd.enable` or `nodes.clightning.enable` must be `true`.
        '';
      }
    ];

    services.lnd.enable = mkIf cfg.nodes.lnd.enable true;
    services.lightning-loop.enable = mkIf lndLoopEnabled true;
    services.clightning = mkIf cfg.nodes.clightning.enable {
      enable = true;
      plugins.clnrest.enable = true;
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0770 ${cfg.user} ${cfg.group} - -"
    ] ++ optional cfg.nodes.lnd.enable
      # `rtl-copy-macaroon` installs the macaroon as the rtl user, which needs write
      # access to this dir. Older versions created it as root, so fix its owner.
      "d '${cfg.dataDir}/macaroons' 0770 ${cfg.user} ${cfg.group} - -";

    services.rtl.tor.enforce = mkIf (cfg.extraCurrency != null) false;

    systemd.services.rtl = rec {
      wantedBy = [ "multi-user.target" ];
      wants = optional cfg.nodes.clightning.enable "clightning.service" ++
              optional cfg.nodes.lnd.enable "lnd.service";
      after = wants ++ [ "nix-bitcoin-secrets.target" ];
      environment.RTL_CONFIG_PATH = cfg.dataDir;
      environment.DB_DIRECTORY_PATH = cfg.dataDir;
      serviceConfig = nbLib.defaultHardening // {
        ExecStartPre = [
          (nbLib.script "rtl-setup-config" ''
            <${configFile} sed "s|@multiPass@|$(cat ${secretsDir}/rtl-password)|" \
              > '${cfg.dataDir}/RTL-Config.json'
          '')
        ]
        ++ optional cfg.nodes.lnd.enable
          # The lnd admin macaroon is not readable by group `lnd`, so copy it
          (nbLib.rootScript "rtl-copy-macaroon" ''
            ${installAsRtl}
            ${runuser} -u ${lnd.user} -- head -c 65536 '${lnd.networkDir}/admin.macaroon' > "$tmpFile"
            if [[ ! -s $tmpFile ]]; then
              echo "Error: '${lnd.networkDir}/admin.macaroon' is empty" >&2
              exit 1
            fi
            installAsRtl '${cfg.dataDir}/macaroons/admin.macaroon'
          '')
        ++ optional cfg.nodes.clightning.enable
          (nbLib.rootScript "rtl-create-clnrest-rune-file" ''
            ${installAsRtl}
            rune=$(${runuser} -u ${clightning.user} -- head -c 65536 '${clightning.networkDir}/admin-rune')
            if [[ ! $rune ]]; then
              echo "Error: '${clightning.networkDir}/admin-rune' is empty" >&2
              exit 1
            fi
            printf 'LIGHTNING_RUNE="%s"\n' "$rune" > "$tmpFile"
            installAsRtl '${runePath}'
          '');
        ExecStart = "${nbPkgs.rtl}/bin/rtl";
        # Show "rtl" instead of "node" in the journal
        SyslogIdentifier = "rtl";
        User = cfg.user;
        Restart = "on-failure";
        RestartSec = "10s";
        ReadWritePaths = [ cfg.dataDir ];
      } // nbLib.allowedIPAddresses cfg.tor.enforce
        // nbLib.nodejs;
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = optional lndLoopEnabled lnd.group;
    };
    users.groups.${cfg.group} = {};

    nix-bitcoin.secrets.rtl-password.user = cfg.user;
    nix-bitcoin.generateSecretsCmds.rtl = ''
      makePasswordSecret rtl-password
    '';
  };
}
