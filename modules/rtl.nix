{ config, lib, pkgs, ... }:

with lib;
let
  options.services.rtl = {
    enable = mkEnableOption "Ride The Lightning, a web interface for LND and Core Lightning";
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "IP address of the web interface.";
    };
    port = mkOption {
      type = types.port;
      default = 3000;
      description = "Port of the web interface.";
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
          description = "Enable the Core Lightning node interface.";
        };
        extraConfig = mkOption {
          type = with types; attrsOf anything;
          default = {};
          example = {
            Settings.userPersona = "MERCHANT";
            Settings.logLevel = "DEBUG";
          };
          description = ''
            Extra Core Lightning node configuration.

            ${nbLib.extraConfigDescription}

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
        extraConfig = mkOption {
          type = with types; attrsOf anything;
          default = {};
          example = {
            Settings.userPersona = "MERCHANT";
            Settings.logLevel = "DEBUG";
          };
          description = ''
            Extra lnd node configuration.

            ${nbLib.extraConfigDescription}

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
          By default, Core Lightning is shown before LND.
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
  # RTL reads `admin.macaroon` in `macaroonPath`. Earlier versions copied the admin
  # credentials to these paths, so keeping them overwrites those copies.
  macaroonCopy = "${cfg.dataDir}/macaroons/admin.macaroon";
  runePath = "${cfg.dataDir}/clightning-admin-rune";
  unusedCopies = optional (!cfg.nodes.lnd.enable) macaroonCopy
                 ++ optional (!cfg.nodes.clightning.enable) runePath;

  # RTL's lnd macaroon allows only the RPCs of the lnd REST routes in RTL's
  # `backend/controllers/lnd`, as `uri` permissions. lnd's wallet unlocker RPCs
  # need no macaroon. Entity permissions would allow more, like `offchain:write`
  # for `DeleteAllPayments`. So when an RTL update calls another RPC, add it here.
  lndRpcs = map (rpc: "/lnrpc.Lightning/${rpc}") [
    "AddInvoice" "ClosedChannels" "CloseChannel" "ConnectPeer" "DecodePayReq"
    "DescribeGraph" "DisconnectPeer" "ExportAllChannelBackups" "ExportChannelBackup"
    "FeeReport" "ForwardingHistory" "GetChanInfo" "GetInfo" "GetNetworkInfo"
    "GetNodeInfo" "GetTransactions" "ListChannels" "ListInvoices" "ListPayments"
    "ListPeers" "NewAddress" "OpenChannelSync" "PendingChannels" "QueryRoutes"
    "RestoreChannelBackups" "SendCoins" "SignMessage" "UpdateChannelPolicy"
    "VerifyChanBackup" "VerifyMessage" "WalletBalance"
  ] ++ [ "/routerrpc.Router/SendPaymentV2" "/routerrpc.Router/TrackPaymentV2" ];
  # lnd has these RPCs only when its package has the build tags `invoicesrpc` and
  # `walletrpc`. bitcoinix's lnd has both. Without them, RTL still starts, but its
  # features that use these RPCs fail.
  optionalLndRpcs = [
    "/invoicesrpc.Invoices/LookupInvoiceV2" "/invoicesrpc.Invoices/SubscribeSingleInvoice"
  ] ++ map (rpc: "/walletrpc.WalletKit/${rpc}") [
    "BumpFee" "LabelTransaction" "LeaseOutput" "ListUnspent" "ReleaseOutput"
  ];

  # RTL's clightning rune allows only the methods in RTL's `backend/controllers/cln`.
  # clnrest checks `listclnrest-notifications` for RTL's websocket connection.
  clightningMethods = [
    "autoclean-once" "checkmessage" "close" "connect" "decode" "disableoffer"
    "disconnect" "feerates" "fetchinvoice" "fundchannel" "funderupdate" "getinfo"
    "getroute" "invoice" "keysend" "listchannels" "listclnrest-notifications"
    "listconfigs" "listforwards" "listfunds" "listinvoices" "listnodes" "listoffers"
    "listpeerchannels" "listpeers" "listsendpays" "newaddr" "offer" "pay"
    "setchannel" "signmessage" "withdraw"
  ];
  # A comment restriction, which clightning ignores when it checks the rune.
  # It marks the runes that `rtl-create-clnrest-rune-file` creates.
  runeMarker = "bitcoinix-rtl#";
  runeRestrictions = builtins.toJSON [
    (map (method: "method=${method}") clightningMethods)
    [ runeMarker ]
  ];
  # In clightning's network dir, which RTL can't write. RTL had the admin rune
  # before, so a file that RTL can change must not decide which rune is revoked.
  clightningRune = "${clightning.networkDir}/rtl-rune";
  # clightning gives a new rune the next unique ID, also when this ID is
  # blacklisted. So RTL's start creates up to this many runes in a row.
  maxRuneAttempts = 10;
  # Reads the output of `showrunes`, which lists the runes that clightning stored.
  # Prints "keep" while the stored rune in `rtl-rune` has RTL's restrictions and
  # isn't blacklisted, else "create". Then it prints the unique IDs of all other
  # runes with the marker that aren't blacklisted, one per line. These are RTL's
  # earlier runes, for example ones with other restrictions or ones that a lost
  # `rtl-rune` left behind. Blacklisting an ID revokes every rune with this ID.
  # clightning gives each new rune its own ID, but it counts them in its database.
  # So after a start on a new database, a new rune can get the ID of an older rune
  # that clightning doesn't list, see `docs/service/rtl.md`.
  runeAction = builtins.toFile "rtl-rune-action.jq" ''
    def restrictions: [.restrictions[] | [.alternatives[] | .fieldname + .condition + .value]];
    [.runes[] | select(.blacklisted | not)] as $valid
    | (first($valid[] | select(.rune == $rune and restrictions == $want)) // null) as $kept
    | (if $kept then "keep" else "create" end),
      ($valid[] | select((restrictions | any(. == [$marker])) and .unique_id != $kept.unique_id)
       | .unique_id)
  '';

  runuser = "${pkgs.util-linux}/bin/runuser";

  backends = optional cfg.nodes.clightning.enable "clightning" ++
             optional cfg.nodes.lnd.enable "lnd";

  # Added to the units of the backends, see `systemd.services.rtl`.
  # `--no-block`: RTL's start waits for the backend's start job, which
  # includes this command. So a blocking start would deadlock.
  # `--job-mode=ignore-requirements`: otherwise RTL's `bindsTo` would also
  # start the other backend while it's stopped, during maintenance or before
  # its `RestartSec`. This is safe: systemd starts RTL only while all backends
  # that it's bound to and ordered after are active. Otherwise the start fails
  # with "Bound to unit ..., but unit isn't active", and the other backend's
  # own start starts RTL later. A start queued while the other backend is
  # starting waits for it.
  # `-`: when systemctl fails, for example because RTL is masked, the backend
  # still starts. `+`: run as root, which systemctl needs to start a unit.
  startRtl = {
    serviceConfig.ExecStartPost = [
      "-+${config.systemd.package}/bin/systemctl start --no-block --job-mode=ignore-requirements rtl.service"
    ];
  };

  inherit (nbLib) optionalAttr;

  # RTL connects to this URL, and `pin-backend-certs.cjs` pins the backend's cert for it
  backendUrl = isLnd: "https://${
    if isLnd
    then nbLib.addressWithPort lnd.restAddress lnd.restPort
    else nbLib.addressWithPort clightning.plugins.clnrest.address clightning.plugins.clnrest.port
  }";

  # clnrest's server cert, which `rtl-create-clnrest-rune-file` copies from a
  # dir that RTL can't read. The cert itself, not the CA that issued it: any
  # cert from that CA would pass, because the pin skips the hostname check.
  clnrestCertCopy = "${cfg.dataDir}/clnrest-cert.pem";

  # Read by `./rtl/pin-backend-certs.cjs`: for each backend URL, the server's
  # own cert. RTL can read lnd's cert, which is world-readable.
  backendCerts = pkgs.writeText "rtl-backend-certs.json" (builtins.toJSON (
    optionalAttrs cfg.nodes.lnd.enable { ${backendUrl true} = lnd.certPath; } //
    optionalAttrs cfg.nodes.clightning.enable { ${backendUrl false} = clnrestCertCopy; }
  ));

  node = { isLnd, index }: {
    inherit index;
    lnNode = "Node";
    lnImplementation = if isLnd then "LND" else "CLT";
    Authentication = {
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
      lnServerUrl = backendUrl isLnd;
    };
  };

  clightningNode = recursiveUpdate (node { isLnd = false; index = 1; })
    cfg.nodes.clightning.extraConfig;
  lndNode = recursiveUpdate (node { isLnd = true; index = 2; }) cfg.nodes.lnd.extraConfig;

  nodes' = optional cfg.nodes.clightning.enable clightningNode ++
           optional cfg.nodes.lnd.enable lndNode;

  nodes = if cfg.nodes.reverseOrder then reverseList nodes' else nodes';

  # RTL sends a backend's credential to its URL, which may also be plain HTTP.
  # So it must be the URL that `pin-backend-certs.cjs` pins for this backend.
  # Compare by node, as `extraConfig` can also change `lnImplementation`.
  urlOverrides = let
    overridden = rtlNode: isLnd: rtlNode.Settings.lnServerUrl or null != backendUrl isLnd;
  in optional (cfg.nodes.clightning.enable && overridden clightningNode false) "clightning"
     ++ optional (cfg.nodes.lnd.enable && overridden lndNode true) "lnd";

  # RTL's web interface is plain HTTP with one password. In the host's network
  # namespace, any local user could take RTL's port while RTL is stopped, serve a
  # fake login page and collect the password. So a socket unit holds the port
  # from boot on, also while RTL is stopped, and `rtl-proxy` forwards each
  # connection to RTL's unix socket.
  # With netns-isolation, RTL's address exists only in RTL's namespace, which only
  # root can enter. So RTL keeps listening on it directly.
  useProxy = !config.nix-bitcoin.netns-isolation.enable;
  # In RTL's runtime dir, which systemd removes at each stop and creates for each
  # start, accessible only to RTL's user. So no other user can take the path.
  socketPath = "/run/rtl/rtl.sock";
  rtlConfig = {
    # Set at service start from the secret file, see `rtl-setup-config`
    multiPass = null;
    # Without `host`, RTL listens on a unix socket when `port` isn't a number
    ${optionalAttr (!useProxy) "host"} = cfg.address;
    port = if useProxy then socketPath else cfg.port;
    SSO.rtlSSO = 0;
    inherit nodes;
  };

  configFile = builtins.toFile "config" (builtins.toJSON rtlConfig);

  # Loads `pin-backend-certs.cjs`. Checked by an assertion, because a
  # `mkForce` on `NODE_OPTIONS` would drop it.
  requirePins = "--require=${./rtl/pin-backend-certs.cjs}";

  inherit (config.services)
    lnd
    clightning;
in {
  imports = [ (import ./web-interface-proxy.nix {
    name = "rtl";
    inherit socketPath;
    inherit (cfg) user;
  }) ];
  inherit options;

  config = mkIf cfg.enable {
    warnings =
      optional (cfg.nodes.clightning.enable && cfg.nodes.clightning.extraConfig != {})
        (nbLib.extraConfigWarning "services.rtl.nodes.clightning.extraConfig")
      ++ optional (cfg.nodes.lnd.enable && cfg.nodes.lnd.extraConfig != {})
        (nbLib.extraConfigWarning "services.rtl.nodes.lnd.extraConfig");

    assertions = [
      { assertion = cfg.nodes.clightning.enable || cfg.nodes.lnd.enable;
        message = ''
          RTL: At least one of `nodes.lnd.enable` or `nodes.clightning.enable` must be `true`.
        '';
      }
      # Not `hasInfix`: its regex can't contain the store path
      { assertion = elem requirePins (splitString " "
          (toString (config.systemd.services.rtl.environment.NODE_OPTIONS or "")));
        message = ''
          RTL: `systemd.services.rtl.environment.NODE_OPTIONS` must contain
          `${requirePins}`. It makes RTL check the TLS certificates of its backends.
        '';
      }
      { assertion = urlOverrides == [];
        message = ''
          RTL: Remove `Settings.lnServerUrl` from
          `services.rtl.nodes.${head urlOverrides}.extraConfig`. RTL checks the TLS
          certificates of its backends only at the URLs that bitcoinix sets.
        '';
      }
    ];

    services.lnd = mkIf cfg.nodes.lnd.enable {
      enable = true;
      macaroons.rtl = {
        inherit (cfg) user;
        permissions = nbLib.uriPermissions lndRpcs;
        optionalPermissions = nbLib.uriPermissions optionalLndRpcs;
      };
    };
    services.clightning = mkIf cfg.nodes.clightning.enable {
      enable = true;
      plugins.clnrest.enable = true;
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0770 ${cfg.user} ${cfg.group} - -"
      # `rtl-copy-macaroon` installs the macaroon as the rtl user, and RTL's start
      # removes it as that user when RTL doesn't use lnd. So the rtl user needs write
      # access to this dir. Older versions created it as root, so fix its owner.
      "d '${cfg.dataDir}/macaroons' 0770 ${cfg.user} ${cfg.group} - -"
    ];

    services.rtl.tor.enforce = mkIf (cfg.extraCurrency != null) false;

    systemd.services.rtl = rec {
      # RTL sends its lnd macaroon and its clightning rune to its backends, but
      # doesn't check their TLS certificates. So Node preloads
      # `pin-backend-certs.cjs` (`NODE_OPTIONS`): a connection to a backend must
      # present the backend's pinned cert, and every other connection gets the
      # normal checks against the system CAs.
      # TODO-EXTERNAL: Drop the preload once RTL can verify its backends'
      # certificates itself.
      # As a second guard, RTL doesn't run while a backend is down, when
      # another local process could take over the backend's port.
      # `bindsTo` with `after` stops RTL whenever a backend stops, crashes or
      # exits. It doesn't start RTL again when the backend comes back, so each
      # backend starts RTL from its `ExecStartPost` (`startRtl`). `after` holds
      # that start until the backend's start job, including its readiness
      # checks, has finished.
      # Starting RTL through `wantedBy` on the backends would make a backend
      # that sends STOPPING=1 as it shuts down, like lnd, restart at once
      # instead of after its `RestartSec`.
      bindsTo = map (backend: "${backend}.service") backends;
      wantedBy = [ "multi-user.target" ];
      after = bindsTo ++ [ "nix-bitcoin-secrets.target" ];
      environment.RTL_CONFIG_PATH = cfg.dataDir;
      environment.DB_DIRECTORY_PATH = cfg.dataDir;
      environment.NODE_OPTIONS = requirePins;
      environment.RTL_BACKEND_CERTS = backendCerts;
      serviceConfig = nbLib.defaultHardening // {
        ExecStartPre = [
          # jq reads the password from the file itself. A sed program would carry
          # the password in its argv, readable by every local user through
          # /proc/<pid>/cmdline while it runs. jq also escapes it as JSON.
          (nbLib.script "rtl-setup-config" ''
            conf='${cfg.dataDir}/RTL-Config.json'
            # RTL keeps the 2FA secret set up in its UI in this file as `secret2FA`
            # and enables 2FA when it is set. So carry it over from the old file,
            # which jq also reads itself. Ignore a missing or empty file, or one that
            # jq doesn't read as exactly one object.
            old=/dev/null
            if [[ -s $conf ]] && ${pkgs.jq}/bin/jq -es 'length == 1 and (.[0] | type == "object")' "$conf" >/dev/null 2>&1; then
              old=$conf
            elif [[ -e $conf ]]; then
              # For example after a crash while RTL rewrote the file
              echo "Warning: Ignore '$conf', which isn't a single JSON object." \
                   "2FA is off until you set it up again." >&2
            fi
            # Write to a temp file. `>` would truncate "$conf" before jq reads it.
            tmp=$(mktemp "$conf.XXXXXX")
            trap 'rm -f "$tmp"' EXIT
            ${pkgs.jq}/bin/jq --rawfile pw '${secretsDir}/rtl-password' --slurpfile old "$old" '
              .multiPass = ($pw | sub("\n+$"; ""))
              | ($old[0].secret2FA? // null) as $secret
              | if ($secret | type) == "string" and $secret != ""
                then .secret2FA = $secret else . end
            ' ${configFile} > "$tmp"
            mv -f "$tmp" "$conf"
          '')
        ]
        ++ optional (unusedCopies != [])
          # Earlier versions copied the admin credentials of both backends to RTL.
          # Remove the copy of a backend that RTL doesn't use. Runs as the rtl user.
          "${pkgs.coreutils}/bin/rm -f ${escapeShellArgs unusedCopies}"
        ++ optional cfg.nodes.lnd.enable
          # Copy the macaroon that lnd creates for RTL (`services.lnd.macaroons.rtl`)
          # to the file that RTL reads. Runs as the rtl user, who owns both the
          # macaroon and the destination.
          # The lnd user can write `/run/lnd`. So don't follow a symlink, which could
          # make this copy a file of the rtl user, and RTL send it to lnd.
          (nbLib.script "rtl-copy-macaroon" ''
            umask 077
            tmp=$(mktemp)
            trap 'rm -f "$tmp"' EXIT
            dd if=/run/lnd/rtl.macaroon iflag=nofollow,fullblock bs=65536 count=1 status=none > "$tmp"
            if [[ ! -s $tmp ]]; then
              echo "Error: '/run/lnd/rtl.macaroon' is empty" >&2
              exit 1
            fi
            install --compare -m 640 -D "$tmp" '${macaroonCopy}'
          '')
        ++ optional cfg.nodes.clightning.enable
          # Runs as root to bridge clightning and rtl credentials. Neither user's
          # dir is accessed as root: read as clightning into a root-owned temp dir
          # and install into `cfg.dataDir` as rtl.
          (nbLib.rootScript "rtl-create-clnrest-rune-file" ''
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
            asClightning() {
              ${runuser} -u ${clightning.user} -- "$@"
            }
            cli() {
              asClightning ${clightning.package}/bin/lightning-cli --lightning-dir='${clightning.dataDir}' "$@"
            }
            jq=${pkgs.jq}/bin/jq
            restrictions=${escapeShellArg runeRestrictions}

            # Create RTL's rune once and keep it, see `runeAction`.
            # Pass the rune to jq in a file: arguments are visible to all local users.
            checkRune() {
              local actions
              if ! actions=$(cli showrunes | $jq -r --rawfile rune <(printf '%s' "$rune") \
                               --argjson want "$restrictions" --arg marker ${escapeShellArg runeMarker} \
                               -f ${runeAction}); then
                echo "Error: Can't check RTL's rune" >&2
                exit 1
              fi
              { read -r action; mapfile -t earlierRunes; } <<< "$actions"
            }
            rune=$(asClightning head -c 65536 '${clightningRune}' 2>/dev/null || true)
            checkRune
            # Revoke RTL's earlier runes before it creates a new one, so that a failed
            # start revokes them too
            for id in "''${earlierRunes[@]}"; do
              echo "Revoke RTL's earlier rune with unique ID $id"
              cli blacklistrune "$id" "$id" > /dev/null
            done
            if [[ $action != keep ]]; then
              if [[ $rune ]]; then
                echo "'${clightningRune}' holds no stored rune with RTL's restrictions. Create a new one."
              fi
              # Check each new rune too, see `maxRuneAttempts`
              for (( attempt = 1; ; attempt++ )); do
                if ! response=$(cli createrune restrictions="$restrictions") ||
                   ! rune=$($jq -er .rune <<< "$response") || [[ ! $rune ]]; then
                  echo "Error: Can't create RTL's rune: $response" >&2
                  exit 1
                fi
                checkRune
                if [[ $action == keep ]]; then
                  break
                fi
                id=$($jq -r .unique_id <<< "$response")
                if (( attempt == ${toString maxRuneAttempts} )); then
                  echo "Error: The unique IDs of RTL's last $attempt new runes, up to $id, are" \
                       "blacklisted. RTL's next start tries the next IDs." >&2
                  exit 1
                fi
                echo "RTL's new rune has the blacklisted unique ID $id. Create another one."
              done
              # Replace the file in one step, so that a crash can't leave a partial rune
              asClightning ${nbLib.writeAtomic} '${clightningRune}' <<< "$rune"
            fi
            printf 'LIGHTNING_RUNE="%s"\n' "$rune" > "$tmpFile"
            installAsRtl '${runePath}'

            # Copy clnrest's cert for `pin-backend-certs.cjs`. Ask clightning for
            # clnrest's cert dir, which `clnrest-certs` can change.
            # The query fails when clnrest isn't running, for example because
            # another process took its port. `Restart=on-failure` tries again.
            if ! response=$(cli listconfigs clnrest-certs) ||
               ! cert=$(${clightning.plugins.clnrest.serverCertPathFromConfigs} <<< "$response"); then
              echo "Error: Can't get clnrest's cert dir from clightning: $response" >&2
              exit 1
            fi
            # clnrest creates the cert before it listens, which clightning's start
            # waits for. When it's still missing, `Restart=on-failure` tries again.
            asClightning head -c 65536 "$cert" > "$tmpFile"
            if [[ ! -s $tmpFile ]]; then
              echo "Error: '$cert' is empty" >&2
              exit 1
            fi
            installAsRtl '${clnrestCertCopy}'
          '');
        ExecStart = "${nbPkgs.rtl}/bin/rtl";
        # Show "rtl" instead of "node" in the journal
        SyslogIdentifier = "rtl";
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = "10s";
        ReadWritePaths = [ cfg.dataDir ];
      } // optionalAttrs useProxy {
        RuntimeDirectory = "rtl";
        RuntimeDirectoryMode = "0700";
        # RTL prefers them to its config file, so they would move it off its unix
        # socket. This also drops them from an `EnvironmentFile`.
        UnsetEnvironment = [ "PORT" "HOST" ];
      } // nbLib.allowedIPAddresses cfg.tor.enforce
        // nbLib.nodejs;
    };

    systemd.services.lnd = mkIf cfg.nodes.lnd.enable startRtl;
    systemd.services.clightning = mkIf cfg.nodes.clightning.enable startRtl;

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
    };
    users.groups.${cfg.group} = {};

    nix-bitcoin.secrets.rtl-password.user = cfg.user;
    nix-bitcoin.generateSecretsCmds.rtl = ''
      makePasswordSecret rtl-password
    '';
  };
}
