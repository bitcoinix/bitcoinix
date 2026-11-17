{ config, lib, pkgs, ... }:

with lib;
let
  options.services.unbeholden-lnurl = {
    enable = mkEnableOption "Unbeholden LNURL, a Lightning Address server";
    backend = mkOption {
      type = types.enum [ "lnd" "cln" ];
      default = "lnd";
      description = "The local Lightning node that creates invoices and pays vouchers.";
    };
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "HTTP server address.";
    };
    port = mkOption {
      type = types.port;
      default = 8081;
      description = "HTTP server port.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/unbeholden-lnurl";
      description = "The data directory, holding settlement cursors, voucher claims and zap receipts.";
    };
    user = mkOption {
      type = types.str;
      default = "unbeholden-lnurl";
      description = "The user as which to run Unbeholden LNURL.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      defaultText = "config.services.unbeholden-lnurl.user";
      description = "The group as which to run Unbeholden LNURL.";
    };
    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.unbeholden-lnurl;
      defaultText = "config.nix-bitcoin.pkgs.unbeholden-lnurl";
      description = "The package providing Unbeholden LNURL.";
    };
    settings = mkOption {
      type = types.submodule (settings: {
        freeformType = yaml.type;
        options = {
          trusted_proxies = mkOption {
            type = with types; listOf str;
            default = [];
            description = "IP addresses or CIDRs of reverse proxies whose `X-Forwarded-*` headers are trusted.";
          };
          outbound_proxy = mkOption {
            type = with types; nullOr str;
            default = null;
            description = "SOCKS5 proxy for ntfy notifications and Nostr publishing.";
          };
          verify_key_file = mkOption {
            type = types.str;
            default = "${secretsDir}/unbeholden-lnurl-verify";
            defaultText = "\${config.nix-bitcoin.secretsDir}/unbeholden-lnurl-verify";
            description = "File with the key for verify URLs. Changing it invalidates old verify URLs.";
          };
          withdraw_secret_file = mkOption {
            type = with types; nullOr str;
            default = if settings.config ? withdraw_secret then null
              else "${secretsDir}/unbeholden-lnurl-withdraw";
            defaultText = "\${config.nix-bitcoin.secretsDir}/unbeholden-lnurl-withdraw, or null if `withdraw_secret` is set";
            description = "File with the voucher secret. Changing it changes every voucher URL.";
          };
          addresses = mkOption {
            type = types.attrsOf (types.submodule {
              freeformType = yaml.type;
              options = {
                min_sendable = mkOption {
                  type = types.ints.positive;
                  description = "Minimum amount in millisatoshis.";
                };
                max_sendable = mkOption {
                  type = types.ints.positive;
                  description = "Maximum amount in millisatoshis.";
                };
              };
            });
            default = {};
            description = "Lightning Addresses by user name, or `*` for any name.";
          };
          withdraw = mkOption {
            type = with types; listOf (attrsOf yaml.type);
            default = [];
            description = "Withdrawal vouchers.";
          };
          notifications.ntfy = mkOption {
            type = with types; nullOr (attrsOf yaml.type);
            default = null;
            description = ''
              ntfy settlement notifications. Set `token_file` instead of `token`, so that
              the token stays out of the Nix store.
            '';
          };
          nostr = mkOption {
            type = types.nullOr (types.submodule {
              freeformType = yaml.type;
              options.private_key_file = mkOption {
                type = types.str;
                default = "${secretsDir}/unbeholden-lnurl-nostr";
                defaultText = "\${config.nix-bitcoin.secretsDir}/unbeholden-lnurl-nostr";
                description = "File with the Nostr private key.";
              };
            });
            default = null;
            description = "Nostr zap receipts. Set to `{}` to enable them.";
          };
        };
      });
      default = {};
      description = ''
        Unbeholden LNURL configuration. See the
        [example config](https://github.com/unbeholdendev/unbeholden-lnurl/blob/main/config.example.yaml).
        `listen`, `state_dir` and the node connection are set by this module.
        The config is world-readable in the Nix store: put secrets in files.
      '';
    };
    tor = nbLib.tor;
  };

  cfg = config.services.unbeholden-lnurl;
  nbLib = config.nix-bitcoin.lib;
  secretsDir = config.nix-bitcoin.secretsDir;
  lnd = config.services.lnd;
  cln = config.services.clightning;
  clnrest = cln.plugins.clnrest;
  yaml = pkgs.formats.yaml {};

  isLnd = cfg.backend == "lnd";
  backendUnit = if isLnd then "lnd" else "clightning";
  receiving = cfg.settings.addresses != {};
  withdraw = cfg.settings.withdraw != [];
  subscribing = cfg.settings.notifications.ntfy != null || cfg.settings.nostr != null;
  generateWithdrawSecret = cfg.settings.withdraw_secret_file != null;

  runeFile = "${cfg.dataDir}/cln-rune";
  listVouchers = pkgs.writers.writeBashBin "unbeholden-lnurl-vouchers" ''
    exec ${pkgs.util-linux}/bin/runuser -u ${cfg.user} -- \
      ${getExe cfg.package} -config ${configFile} -list-vouchers
  '';
  removeNulls = value:
    if isAttrs value then mapAttrs (_: removeNulls) (filterAttrs (_: v: v != null) value)
    else if isList value then map removeNulls value
    else value;
  configFile = yaml.generate "unbeholden-lnurl.yaml" (removeNulls cfg.settings // {
    listen = nbLib.addressWithPort cfg.address cfg.port;
    state_dir = cfg.dataDir;
  } // (if isLnd then {
    lnd = {
      host = nbLib.addressWithPort lnd.rpcAddress lnd.rpcPort;
      tls_cert = lnd.certPath;
      macaroon = "/run/lnd/unbeholden-lnurl.macaroon";
    };
  } else {
    cln = {
      url = "https://${nbLib.addressWithPort clnrest.address clnrest.port}";
      rune_file = runeFile;
      ca_cert = "/run/unbeholden-lnurl/ca.pem";
    };
  }));

  lndPermissions = optional receiving "invoices:write"
    ++ optional (receiving || subscribing) "invoices:read"
    ++ optionals withdraw [ "offchain:write" "info:read" ];
  clnMethods = optional receiving "invoice"
    ++ optional (receiving || subscribing) "listinvoices"
    ++ optional subscribing "waitanyinvoice"
    ++ optionals withdraw [ "pay" "listpays" "getinfo" ];
  runeRestrictions = builtins.toJSON [ (map (method: "method=${method}") clnMethods) ];

  # Reuse the rune while its restrictions stay the same. Otherwise revoke it, so
  # that no rune with the old permissions remains valid.
  setupCln = nbLib.rootScript "unbeholden-lnurl-setup-cln" ''
    cli() {
      ${pkgs.util-linux}/bin/runuser -u ${cln.user} -- ${cln.cli}/bin/lightning-cli "$@"
    }
    jq=${pkgs.jq}/bin/jq
    restrictions=${escapeShellArg runeRestrictions}
    umask 077

    if [[ -s ${runeFile} && $(< ${runeFile}.restrictions) != "$restrictions" ]]; then
      id=$(cli showrunes "$(< ${runeFile})" | $jq -er '.runes[0].unique_id')
      cli blacklistrune "$id" "$id" > /dev/null
      rm ${runeFile}
    fi
    if [[ ! -s ${runeFile} ]]; then
      cli createrune restrictions="$restrictions" | $jq -er .rune > ${runeFile}.tmp
      printf '%s' "$restrictions" > ${runeFile}.restrictions
      chown ${cfg.user}:${cfg.group} ${runeFile}.tmp ${runeFile}.restrictions
      mv -T ${runeFile}.tmp ${runeFile}
    fi

    certsDir=$(cli listconfigs clnrest-certs | $jq -er '.configs["clnrest-certs"].value_str // ""')
    case $certsDir in
      "") certsDir=${cln.networkDir} ;;
      /*) ;;
      *) certsDir=${cln.networkDir}/$certsDir ;;
    esac
    install -m 400 -o ${cfg.user} -g ${cfg.group} "$certsDir/ca.pem" /run/unbeholden-lnurl/ca.pem
  '';
in {
  inherit options;

  config = mkIf cfg.enable {
    assertions = [ {
      assertion = receiving || withdraw || subscribing;
      message = "services.unbeholden-lnurl requires addresses, withdraw vouchers, notifications or nostr in its settings.";
    } ];

    services.lnd = mkIf isLnd {
      enable = true;
      macaroons.unbeholden-lnurl = {
        inherit (cfg) user;
        permissions = concatMapStringsSep "," (permission:
          let parts = splitString ":" permission;
          in builtins.toJSON { entity = head parts; action = last parts; }
        ) lndPermissions;
      };
    };
    services.clightning = mkIf (!isLnd) {
      enable = true;
      plugins.clnrest.enable = true;
    };

    services.unbeholden-lnurl.settings.outbound_proxy = mkIf cfg.tor.proxy
      (mkDefault "socks5://${config.nix-bitcoin.torClientAddressWithPort}");

    environment.systemPackages = optional withdraw listVouchers;

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0700 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.unbeholden-lnurl = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "${backendUnit}.service" ];
      after = [ "${backendUnit}.service" "nix-bitcoin-secrets.target" ];
      serviceConfig = nbLib.defaultHardening // {
        ExecStartPre = optional (!isLnd) setupCln;
        ExecStart = "${getExe cfg.package} -config ${configFile}";
        User = cfg.user;
        Group = cfg.group;
        RuntimeDirectory = "unbeholden-lnurl";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = cfg.dataDir;
        ReadWritePaths = [ cfg.dataDir ];
        Restart = "on-failure";
        RestartSec = "10s";
        # The server waits up to 2m10s for open requests when stopping
        TimeoutStopSec = "150s";
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups.${cfg.group} = {};

    nix-bitcoin.secrets = {
      unbeholden-lnurl-verify.user = cfg.user;
      unbeholden-lnurl-withdraw = mkIf generateWithdrawSecret { user = cfg.user; };
      unbeholden-lnurl-nostr = mkIf (cfg.settings.nostr != null) { user = cfg.user; };
    };
    nix-bitcoin.generateSecretsCmds.unbeholden-lnurl = concatMapStrings (name: ''
      if isAbsent ${name}; then
        writeSecret ${name} ${pkgs.openssl}/bin/openssl rand -hex 32
      else
        checkKey ${name} "LNURL identities and voucher URLs"
      fi
    '') ([ "unbeholden-lnurl-verify" ]
      ++ optional generateWithdrawSecret "unbeholden-lnurl-withdraw"
      ++ optional (cfg.settings.nostr != null) "unbeholden-lnurl-nostr");
  };
}
