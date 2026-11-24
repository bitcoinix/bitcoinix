{ config, lib, pkgs, ... }:

with lib;
let
  options.services.unbeholden-lnurl = {
    enable = mkEnableOption "Unbeholden LNURL, a Lightning Address server";
    backend = mkOption {
      type = types.enum [ "lnd" "clightning" ];
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
  receiving = cfg.settings.addresses != {};
  withdraw = cfg.settings.withdraw != [];
  subscribing = cfg.settings.notifications.ntfy != null || cfg.settings.nostr != null;
  generateWithdrawSecret = cfg.settings.withdraw_secret_file != null;

  runeFile = "${cfg.dataDir}/cln-rune";
  runuser = "${pkgs.util-linux}/bin/runuser";
  listVouchers = pkgs.writers.writeBashBin "unbeholden-lnurl-vouchers" ''
    exec ${runuser} -u ${cfg.user} -- \
      ${getExe cfg.package} -config ${configFile} -list-vouchers
  '';
  removeNulls = value:
    if isAttrs value then mapAttrs (_: removeNulls) (filterAttrs (_: v: v != null) value)
    else if isList value then map removeNulls value
    else value;
  configFile = yaml.generate "unbeholden-lnurl.yaml" (removeNulls cfg.settings // {
    listen = let
      bare = removePrefix "[" (removeSuffix "]" cfg.address);
    in "${if hasInfix ":" bare then "[${bare}]" else bare}:${toString cfg.port}";
    state_dir = cfg.dataDir;
  } // (if isLnd then {
    lnd = {
      host = lnd.rpcEndpoint;
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

  lndMethods = optional receiving "/lnrpc.Lightning/AddInvoice"
    ++ optionals (receiving || subscribing) [
      "/lnrpc.Lightning/LookupInvoice"
      "/lnrpc.Lightning/ListInvoices"
      "/lnrpc.Lightning/SubscribeInvoices"
    ]
    ++ optionals withdraw [ "/routerrpc.Router/SendPaymentV2" "/lnrpc.Lightning/GetInfo" ];
  clnMethods = optional receiving "invoice"
    ++ optional (receiving || subscribing) "listinvoices"
    ++ optional subscribing "waitanyinvoice"
    ++ optionals withdraw [ "pay" "listpays" "getinfo" ];
  runeRestrictions = builtins.toJSON [ (map (method: "method=${method}") clnMethods) ];

  # clightning has no IDs of our own for runes. So it records the rune it
  # created for this service in its data dir, where the service can't write,
  # and revokes that rune when the service no longer uses it. It records the
  # rune, not its ID, because on a new or restored database the ID can belong
  # to another rune.
  recordedRuneFile = "${cln.dataDir}/unbeholden-lnurl-rune";
  recordedRuneId = pkgs.writeText "unbeholden-lnurl-rune-id.jq" ''
    .runes[] | select(.rune == $ENV.recorded and (.blacklisted | not)) | .unique_id
  '';
  revokeRecordedRune = ''
    if [[ -e ${recordedRuneFile} ]]; then
      cli=${cln.cli}/bin/lightning-cli
      id=$($cli showrunes | recorded=$(<${recordedRuneFile}) ${pkgs.jq}/bin/jq -r -f ${recordedRuneId})
      if [[ $id =~ ^[0-9]+$ ]]; then
        $cli blacklistrune "$id" "$id" > /dev/null
      fi
      rm ${recordedRuneFile}
    fi
  '';

  # Keep the recorded rune while the service has it and its restrictions match.
  # Otherwise revoke it, so that no rune with old permissions remains valid.
  runeAction = pkgs.writeText "unbeholden-lnurl-rune-action.jq" ''
    [.runes[] | select(.rune == $ENV.recorded)][0] as $rune
    | if $rune == null or $rune.blacklisted then "create"
      elif $ENV.rune == $ENV.recorded and
        [$rune.restrictions[] | [.alternatives[] | .fieldname + .condition + .value]] == $want
      then "keep"
      else "revoke \($rune.unique_id)" end
  '';
  # `cfg.dataDir` is writable by the service user, and the clightning data dir
  # by the clightning user. So access them only as these users, never as root.
  # The service's rune file only gets compared, never passed to lightning-cli.
  setupCln = nbLib.rootScript "unbeholden-lnurl-setup-cln" ''
    asCln() {
      ${runuser} -u ${cln.user} -- "$@"
    }
    cli() {
      asCln ${cln.cli}/bin/lightning-cli "$@"
    }
    asUser() {
      ${runuser} -u ${cfg.user} -- "$@"
    }
    jq=${pkgs.jq}/bin/jq
    restrictions=${escapeShellArg runeRestrictions}
    umask 077

    action=create
    recorded=$(asCln cat ${recordedRuneFile} 2>/dev/null) || recorded=
    if [[ $recorded ]]; then
      rune=$(asUser head -c 4096 ${runeFile} 2>/dev/null) || rune=
      result=$(cli showrunes \
        | rune=$rune recorded=$recorded $jq -r --argjson want "$restrictions" -f ${runeAction})
      read -r action id <<< "$result"
    fi
    if [[ $action == revoke ]]; then
      cli blacklistrune "$id" "$id" > /dev/null
    fi
    if [[ $action != keep ]]; then
      rune=$(cli createrune restrictions="$restrictions" | $jq -er .rune)
      asCln tee ${recordedRuneFile}.tmp <<< "$rune" > /dev/null
      asCln mv -T ${recordedRuneFile}.tmp ${recordedRuneFile}
      tmp=$(asUser mktemp ${runeFile}.XXXXXX)
      asUser tee "$tmp" <<< "$rune" > /dev/null
      asUser mv -T "$tmp" ${runeFile}
    fi

    cert=$(cli listconfigs clnrest-certs | ${clnrest.serverCertPathFromConfigs})
    asCln cat "''${cert%/*}/ca.pem" | asUser tee /run/unbeholden-lnurl/ca.pem > /dev/null
  '';
in {
  inherit options;

  config = mkMerge [ (mkIf (cln.enable && !(cfg.enable && !isLnd)) {
    systemd.services.clightning.postStart = mkAfter revokeRecordedRune;
  }) (mkIf cfg.enable {
    assertions = [ {
      assertion = receiving || withdraw || subscribing;
      message = "services.unbeholden-lnurl requires addresses, withdraw vouchers, notifications or nostr in its settings.";
    } ];

    services.lnd = mkIf isLnd {
      enable = true;
      macaroons.unbeholden-lnurl = {
        inherit (cfg) user;
        permissions = concatMapStringsSep ","
          (method: builtins.toJSON { entity = "uri"; action = method; }) lndMethods;
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
      # `requires` stops this with the backend, but doesn't start it again when
      # the backend comes back. The backend starts it, see below.
      requires = [ "${cfg.backend}.service" ];
      after = [ "${cfg.backend}.service" "nix-bitcoin-secrets.target" ];
      # A public Go listener, like lnd's ports. See ./lnd.nix
      environment.GODEBUG = "multipathtcp=0";
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

    # Like `startRtl` in ./rtl.nix: `wantedBy` on the backend would make lnd,
    # which sends STOPPING=1 as it shuts down, restart at once.
    systemd.services.${cfg.backend}.serviceConfig.ExecStartPost = [
      "-+${config.systemd.package}/bin/systemctl start --no-block unbeholden-lnurl.service"
    ];

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
  }) ];
}
