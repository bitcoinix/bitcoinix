{ config, lib, pkgs, ... }:

with lib;
let
  options.services.rtl = {
    enable = mkEnableOption "Ride The Lightning, a web interface for LND and Core Lightning";
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

  rtlConfig = {
    # Set at service start from the secret file, see `rtl-setup-config`
    multiPass = null;
    host = cfg.address;
    port = cfg.port;
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

    services.lnd.enable = mkIf cfg.nodes.lnd.enable true;
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
      # RTL sends the lnd admin macaroon and the clightning admin rune to its
      # backends, but doesn't check their TLS certificates. So Node preloads
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
            # Earlier versions installed an empty or `null` rune when `createrune` failed.
            # clightning replaces it on its next start, and `Restart=on-failure` tries again.
            if [[ ! $rune || $rune == null ]]; then
              echo "Error: '${clightning.networkDir}/admin-rune' is empty or null" >&2
              exit 1
            fi
            printf 'LIGHTNING_RUNE="%s"\n' "$rune" > "$tmpFile"
            installAsRtl '${runePath}'

            # Copy clnrest's cert for `pin-backend-certs.cjs`. Ask clightning for
            # clnrest's cert dir, because its config can set `clnrest-certs` in
            # an included or per-network file. Without it, the dir is clnrest's
            # working dir, the network dir, which is also where a relative dir
            # starts.
            # The query fails when clnrest isn't running, for example because
            # another process took its port. `Restart=on-failure` tries again.
            if ! response=$(${runuser} -u ${clightning.user} -- \
                   ${clightning.cli}/bin/lightning-cli listconfigs clnrest-certs) ||
               ! certsDir=$(${pkgs.jq}/bin/jq -er '.configs["clnrest-certs"].value_str // ""' \
                   <<< "$response"); then
              echo "Error: Can't get clnrest's cert dir from clightning: $response" >&2
              exit 1
            fi
            case $certsDir in
              "") certsDir='${clightning.networkDir}' ;;
              /*) ;;
              *) certsDir='${clightning.networkDir}'/$certsDir ;;
            esac
            cert=$certsDir/server.pem
            # clnrest creates the cert before it listens, which clightning's start
            # waits for. When it's still missing, `Restart=on-failure` tries again.
            ${runuser} -u ${clightning.user} -- head -c 65536 "$cert" > "$tmpFile"
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
        Restart = "on-failure";
        RestartSec = "10s";
        ReadWritePaths = [ cfg.dataDir ];
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
