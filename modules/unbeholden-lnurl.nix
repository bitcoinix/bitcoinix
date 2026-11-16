{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.unbeholden-lnurl;
  nbLib = config.nix-bitcoin.lib;
  lnd = config.services.lnd;
  cln = config.services.clightning;
  rest = cln.plugins.clnrest;
  isLnd = cfg.backend == "lnd";
  withdraw = cfg.settings.withdraw != [];
  subscribe = cfg.settings.notifications.ntfy != null || cfg.settings.nostr != null;
  receiving = cfg.settings.addresses != {};
  secretDir = config.nix-bitcoin.secretsDir;
  opt = type: default: description: mkOption { inherit type default description; };
  str = default: description: opt types.str default description;
  field = type: description: mkOption { inherit type description; };
  nullableString = description: opt (types.nullOr types.str) null description;
  yaml = pkgs.formats.yaml {};
  clean = value:
    if isAttrs value then mapAttrs (_: clean) (filterAttrs (_: v: v != null) value)
    else if isList value then map clean value else value;
  settings = clean cfg.settings // {
    listen = nbLib.addressWithPort cfg.address cfg.port;
    state_dir = cfg.dataDir;
  } // optionalAttrs isLnd {
    lnd = {
      host = nbLib.addressWithPort lnd.rpcAddress lnd.rpcPort;
      tls_cert = lnd.certPath;
      macaroon = "/run/lnd/unbeholden-lnurl.macaroon";
    };
  } // optionalAttrs (!isLnd) {
    cln = {
      url = "https://${nbLib.addressWithPort rest.address rest.port}";
      rune_file = "/run/unbeholden-lnurl/rune";
      ca_cert = "/run/unbeholden-lnurl/ca.pem";
    };
  };
  configFile = yaml.generate "unbeholden-lnurl.yaml" settings;
  methods = optional receiving "invoice"
    ++ optional (receiving || subscribe) "listinvoices"
    ++ optional subscribe "waitanyinvoice"
    ++ optionals withdraw [ "pay" "listpays" "getinfo" ];
  restrictions = builtins.toJSON [ (map (method: "method=" + method) methods) ];
in {
  options.services.unbeholden-lnurl = {
    enable = mkEnableOption "Unbeholden LNURL";
    backend = opt (types.enum [ "lnd" "cln" ]) "lnd" "Local Lightning backend.";
    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.unbeholden-lnurl;
      defaultText = "config.nix-bitcoin.pkgs.unbeholden-lnurl";
      description = "Unbeholden LNURL package.";
    };
    address = str "127.0.0.1" "HTTP listen address.";
    port = opt types.port 8081 "HTTP listen port.";
    dataDir = opt types.path "/var/lib/unbeholden-lnurl" "Persistent settlement cursors, vouchers and zap receipts.";
    user = str "unbeholden-lnurl" "Service user.";
    group = str cfg.user "Service group.";
    tor = nbLib.tor;
    settings = {
      trusted_proxies = opt (types.listOf types.str) [] "Trusted reverse proxy IP addresses or CIDRs.";
      outbound_proxy = nullableString "SOCKS5 proxy for notifications and Nostr publishing.";
      verify_key_file = str "${secretDir}/unbeholden-lnurl-verify" "Runtime file containing the persistent verification key.";
      withdraw_secret_file = str "${secretDir}/unbeholden-lnurl-withdraw" "Runtime file containing the persistent voucher secret.";
      rate_limit = {
        per_minute = opt types.ints.positive 60 "Requests per minute.";
        burst = opt types.ints.positive 30 "Request burst limit.";
      };
      addresses = opt (types.attrsOf (types.submodule {
        options = {
          description = field types.str "Payment description.";
          long_description = nullableString "Long payment description.";
          image_file = nullableString "Runtime path to a PNG or JPEG.";
          success_message = nullableString "Message after payment.";
          min_sendable = field types.ints.positive "Minimum millisatoshis.";
          max_sendable = field types.ints.positive "Maximum millisatoshis.";
        };
      })) {} "Lightning addresses, indexed by user name or wildcard.";
      withdraw = opt (types.listOf (types.submodule {
        options = {
          id = nullableString "Voucher ID.";
          prefix = nullableString "Batch voucher ID prefix.";
          count = opt (types.nullOr types.ints.positive) null "Batch size.";
          domain = field types.str "Voucher domain.";
          description = field types.str "Voucher description.";
          amount = field types.ints.positive "Voucher millisatoshis.";
        };
      })) [] "Withdrawal vouchers.";
      notifications.ntfy = opt (types.nullOr (types.submodule {
        options = {
          url = field types.str "ntfy server URL.";
          topic = field types.str "ntfy topic.";
          token_file = nullableString "Runtime path to the ntfy token.";
        };
      })) null "Settlement notifications.";
      nostr = opt (types.nullOr (types.submodule {
        options.private_key_file = str "${secretDir}/unbeholden-lnurl-nostr" "Runtime path to the persistent Nostr private key.";
      })) null "Enable Nostr zap receipts.";
    };
  };
  config = mkIf cfg.enable {
    assertions = [ {
      assertion = receiving || withdraw || subscribe;
      message = "unbeholden-lnurl requires addresses, withdrawals or notifications.";
    } ];
    services.lnd = mkIf isLnd {
      enable = true;
      macaroons.unbeholden-lnurl = {
        user = cfg.user;
        permissions = concatStringsSep "," (map (p: let parts = splitString ":" p; in builtins.toJSON { entity = head parts; action = last parts; }) (optional receiving "invoices:write"
          ++ optional (receiving || subscribe) "invoices:read"
          ++ optionals withdraw [ "offchain:write" "info:read" ]));
      };
    };
    services.clightning = mkIf (!isLnd) {
      enable = true;
      plugins.clnrest.enable = true;
    };
    services.tor = mkIf cfg.tor.proxy { enable = true; client.enable = true; };
    services.unbeholden-lnurl.settings.outbound_proxy = mkIf cfg.tor.proxy
      (mkDefault "socks5://${config.nix-bitcoin.torClientAddressWithPort}");
    users.users.${cfg.user} = { isSystemUser = true; group = cfg.group; };
    users.groups.${cfg.group} = {};
    systemd.services.unbeholden-lnurl = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "${if isLnd then "lnd" else "clightning"}.service" ];
      after = [ "${if isLnd then "lnd" else "clightning"}.service" "nix-bitcoin-secrets.target" ];
      serviceConfig = nbLib.defaultHardening // {
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = "unbeholden-lnurl";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "unbeholden-lnurl";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = cfg.dataDir;
        ReadWritePaths = [ cfg.dataDir ];
        ExecStart = "${getExe cfg.package} -config ${configFile}";
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStopSec = "150s";
        ExecStartPre = optional (!isLnd) (nbLib.rootScript "unbeholden-lnurl-rune" ''
          cli() {
            ${pkgs.util-linux}/bin/runuser -u ${escapeShellArg cln.user} -- ${cln.cli}/bin/lightning-cli "$@"
          }
          umask 077
          tmp=$(mktemp -d)
          trap 'rm -rf "$tmp"' EXIT
          cli createrune restrictions=${escapeShellArg restrictions} | ${pkgs.jq}/bin/jq -er .rune > "$tmp/rune"
          certsDir=$(cli listconfigs clnrest-certs | ${pkgs.jq}/bin/jq -er '.configs["clnrest-certs"].value_str // ""')
          case "$certsDir" in
            "") certsDir=${escapeShellArg cln.networkDir} ;;
            /*) ;;
            *) certsDir=${escapeShellArg cln.networkDir}/$certsDir ;;
          esac
          install -m 400 -o ${escapeShellArg cfg.user} -g ${escapeShellArg cfg.group} "$tmp/rune" /run/unbeholden-lnurl/rune
          install -m 400 -o ${escapeShellArg cfg.user} -g ${escapeShellArg cfg.group} "$certsDir/ca.pem" /run/unbeholden-lnurl/ca.pem
        '');
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
    };
    systemd.tmpfiles.rules = [ "d '${cfg.dataDir}' 0700 ${cfg.user} ${cfg.group} - -" ];
    nix-bitcoin.secrets = {
      unbeholden-lnurl-verify.user = cfg.user;
      unbeholden-lnurl-withdraw.user = cfg.user;
      unbeholden-lnurl-nostr = mkIf (cfg.settings.nostr != null) { user = cfg.user; };
    };
    nix-bitcoin.generateSecretsCmds.unbeholden-lnurl = ''
      ${concatMapStrings (name: ''
        if isAbsent ${name}; then
          writeSecret ${name} ${pkgs.openssl}/bin/openssl rand -hex 32
        else
          checkKey ${name} "LNURL identities and voucher URLs"
        fi
      '') ([ "unbeholden-lnurl-verify" "unbeholden-lnurl-withdraw" ]
        ++ optional (cfg.settings.nostr != null) "unbeholden-lnurl-nostr")}
    '';
  };
}
