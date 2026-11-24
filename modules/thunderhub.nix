{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.thunderhub;
  inherit (config.services) lnd;
  inherit (config.nix-bitcoin) secretsDir;
  nbLib = config.nix-bitcoin.lib;
  useProxy = !config.nix-bitcoin.netns-isolation.enable;
  socketPath = "/run/thunderhub/thunderhub.sock";

  # ThunderHub saves two-factor enrollment and user preferences in this YAML
  # file. Install it once. Its placeholders are resolved on every start, so a
  # new RPC address, certificate, password or macaroon keeps the enrollment.
  initialAccount = pkgs.writeText "thunderhub-account.yaml" ''
    accounts:
      - name: LND
        serverUrl: "{YML_ENV_1}"
        macaroon: "{YML_ENV_2}"
        certificatePath: "{YML_ENV_3}"
  '';
  rpcHost = nbLib.address (removePrefix "[" (removeSuffix "]" lnd.rpcAddress));
  rpcAddress = if hasInfix ":" rpcHost then "[${rpcHost}]" else rpcHost;

  # RPCs used by ThunderHub's LND provider and subscriptions through the
  # bundled 'lightning' npm package. In particular, don't grant BakeMacaroon,
  # signer RPCs, or DeletePayment (also called for optional probe cleanup).
  rpcPermissions = service: concatMapStringsSep "," (rpc:
    builtins.toJSON { entity = "uri"; action = "/${service}/${rpc}"; });
in {
  imports = [ (import ./web-interface-proxy.nix {
    name = "thunderhub";
    inherit socketPath;
    user = "thunderhub-proxy";
  }) ];

  options.services.thunderhub = {
    enable = mkEnableOption "ThunderHub, a web interface for LND";
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "IP address of the HTTP interface.";
    };
    port = mkOption {
      type = types.ints.between 1 65535;
      default = 3001;
      description = "Port of the HTTP interface.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/thunderhub";
      description = "Directory for ThunderHub's account settings and two-factor enrollment.";
    };
    user = mkOption {
      type = types.str;
      default = "thunderhub";
      description = "User running ThunderHub.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      defaultText = literalExpression "config.services.thunderhub.user";
      description = "Group running ThunderHub.";
    };
    tor.enforce = nbLib.tor.enforce // { default = true; };
  };

  config = mkIf cfg.enable {
    services.lnd = {
      enable = true;
      macaroons.thunderhub = {
        inherit (cfg) user;
        permissions = concatStringsSep "," [
          (rpcPermissions "lnrpc.Lightning" [
            "AddInvoice" "ChannelBalance" "CloseChannel" "ClosedChannels" "ConnectPeer"
            "DecodePayReq" "DisconnectPeer" "ExportAllChannelBackups" "ForwardingHistory"
            "GetChanInfo" "GetInfo" "GetNetworkInfo" "GetNodeInfo" "GetTransactions"
            "ListChannels" "ListInvoices" "ListPayments" "ListPeers" "ListUnspent"
            "LookupInvoice" "NewAddress" "OpenChannel" "PendingChannels" "QueryRoutes"
            "RestoreChannelBackups" "SendCoins" "SignMessage" "SubscribeChannelBackups"
            "SubscribeChannelEvents" "SubscribeInvoices" "UpdateChannelPolicy"
            "VerifyChanBackup" "VerifyMessage" "WalletBalance"
          ])
          (rpcPermissions "routerrpc.Router" [
            "SendPaymentV2" "SendToRouteV2" "SubscribeHtlcEvents" "TrackPaymentV2"
          ])
        ];
        optionalPermissions = concatStringsSep "," [
          (rpcPermissions "chainrpc.ChainNotifier" [ "RegisterBlockEpochNtfn" ])
          (rpcPermissions "invoicesrpc.Invoices" [ "SubscribeSingleInvoice" ])
          (rpcPermissions "verrpc.Versioner" [ "GetVersion" ])
          (rpcPermissions "walletrpc.WalletKit" [ "ListAccounts" "ListUnspent" ])
        ];
      };
    };

    users.users.${cfg.user} = { isSystemUser = true; group = cfg.group; };
    users.groups.${cfg.group} = {};
    systemd.tmpfiles.rules = [ "d '${cfg.dataDir}' 0700 ${cfg.user} ${cfg.group} - -" ];
    nix-bitcoin.secrets.thunderhub-password.permissions = "400";
    nix-bitcoin.generateSecretsCmds.thunderhub = "makePasswordSecret thunderhub-password";

    systemd.services.thunderhub = {
      wantedBy = [ "multi-user.target" ];
      bindsTo = [ "lnd.service" ];
      after = [ "lnd.service" "nix-bitcoin-secrets.target" ];
      environment = {
        ACCOUNT_CONFIG_PATH = "${cfg.dataDir}/accounts.yaml";
        YML_ENV_1 = "${rpcAddress}:${toString lnd.rpcPort}";
        PORT = if useProxy then socketPath else toString cfg.port;
      } // optionalAttrs (!useProxy) { HOST = cfg.address; }
        // optionalAttrs cfg.tor.enforce {
          FETCH_FEES = "false";
          FETCH_PRICES = "false";
          NO_VERSION_CHECK = "true";
        };
      serviceConfig = nbLib.defaultHardening // nbLib.nodejs // nbLib.allowedIPAddresses cfg.tor.enforce // {
        User = cfg.user;
        Group = cfg.group;
        SyslogIdentifier = "thunderhub";
        # Allow the proxy's group to connect to the Unix socket. It can
        # traverse the runtime directory but cannot list or replace its entries.
        UMask = if useProxy then "0007" else "0077";
        ReadWritePaths = [ cfg.dataDir ];
        LoadCredential = [ "password:${secretsDir}/thunderhub-password" "lnd-cert:${lnd.certPath}" ];
        Restart = "on-failure";
        RestartSec = "10s";
        ExecStart = nbLib.script "start-thunderhub" ''
          if [[ ! -e $ACCOUNT_CONFIG_PATH ]]; then
            install -m 600 ${initialAccount} "$ACCOUNT_CONFIG_PATH"
          fi
          MASTER_PASSWORD_OVERRIDE=$(<"$CREDENTIALS_DIRECTORY/password")
          # /run/lnd belongs to lnd. Read as the dashboard user and refuse
          # symlinks, so lnd can't make us send another file in its place.
          YML_ENV_2=$(dd if=/run/lnd/thunderhub.macaroon iflag=nofollow,nonblock,fullblock \
            bs=64K count=1 status=none | base64 -w0)
          YML_ENV_3="$CREDENTIALS_DIRECTORY/lnd-cert"
          if [[ ! $MASTER_PASSWORD_OVERRIDE || ! $YML_ENV_2 || ! -s $YML_ENV_3 ]]; then
            echo "ThunderHub requires a nonempty password, LND macaroon and TLS certificate." >&2
            exit 1
          fi
          export MASTER_PASSWORD_OVERRIDE YML_ENV_2 YML_ENV_3
          exec ${getExe config.nix-bitcoin.pkgs.thunderhub}
        '';
      } // optionalAttrs useProxy {
        RuntimeDirectory = "thunderhub";
        RuntimeDirectoryMode = "0710";
      };
    };

    # Like RTL: wait for lnd's macaroon creation on every start, including
    # after automatic restarts. A synchronous start here would deadlock.
    systemd.services.lnd.serviceConfig.ExecStartPost = [
      "-+${config.systemd.package}/bin/systemctl start --no-block --job-mode=ignore-requirements thunderhub.service"
    ];
    systemd.services.thunderhub-proxy = mkIf useProxy {
      serviceConfig = {
        InaccessiblePaths = [ "/run/lnd" ];
        # A separate UID keeps the login credentials in the dashboard's
        # process environment private. The proxy only shares the socket group.
        DynamicUser = true;
        Group = cfg.group;
      };
    };
  };
}
