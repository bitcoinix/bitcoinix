{ config, lib, pkgs, ... }:

with lib;
let
  options = {
    services.lnd.lndconnect = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Add a `lndconnect` binary to the system environment which prints
          connection info for lnd clients.
          See: https://github.com/LN-Zap/lndconnect

          Usage:
          ```bash
            # Print QR code
            lndconnect

            # Print URL
            lndconnect --url
          ```

          This does not change the listen address of the lnd REST server
          (`services.lnd.restAddress`), which is localhost by default.
          To connect a client, enable `services.lnd.lndconnect.onion`, use
          the WireGuard preset, or set `services.lnd.restAddress` yourself.
        '';
      };
      onion = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Create an onion service for the lnd REST server,
          which is used by lndconnect.
        '';
      };
    };

    services.clightning.plugins.clnrest.lnconnect = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Add a `lnconnect-clnrest` binary to the system environment which prints
          connection info for Core Lightning clients.
          See: https://github.com/LN-Zap/lndconnect

          Usage:
          ```bash
            # Print QR code
            lnconnect-clnrest

            # Print URL
            lnconnect-clnrest --url
          ```

          This does not change the listen address of the clnrest server
          (`services.clightning.plugins.clnrest.address`), which is localhost by default.
          To connect a client, enable
          `services.clightning.plugins.clnrest.lnconnect.onion`, use the
          WireGuard preset, or set the address yourself.
        '';
      };
      onion = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Create an onion service for the clnrest server,
          which is used by lnconnect.
        '';
      };
    };

    nix-bitcoin.mkLndconnect = mkOption {
      readOnly = true;
      default = mkLndconnect;
      description = ''
        A function to create a lndconnect binary.
        See the source for further details.
      '';
    };
  };

  nbLib = config.nix-bitcoin.lib;
  runAsUser = config.nix-bitcoin.runAsUserCmd;

  inherit (config.services)
    lnd
    clightning;

  inherit (clightning.plugins) clnrest;

  mkLndconnect = {
    name,
    shebang ? "#!${pkgs.stdenv.shell} -e",
    isClnrest ? false,
    port,
    authSecretPath,
    enableOnion,
    onionService ? null,
    # Instead of `onionService`: the name of an onion address file in the dir of
    # the user that runs the script, see ./onion-addresses.nix
    userOnionService ? null,
    certPath ? null,
    # Instead of `certPath`: Bash code that prints the cert path.
    # It runs only when the URL includes the cert and the args don't set
    # `--tlscertpath`.
    getCertPathCmd ? null,
    # The user that owns `authSecretPath` and the cert of `getCertPathCmd`.
    # It can replace them with links to files that the caller can read. So when
    # this is set, the script reads only regular files of this user and passes
    # their content to lndconnect through file descriptors.
    secretsOwner ? null
  }:
  let
    useCertPathCmd = getCertPathCmd != null && !enableOnion;
    checkOwner = secretsOwner != null;
    onionDir = config.nix-bitcoin.onionAddresses.dataDir;
    onionFile = if userOnionService != null
      then ''"${onionDir}/$(id -un)/${userOnionService}"''
      else "'${onionDir}/${onionService}'";
    certArg =
      if enableOnion then "--nocert"
      # Empty when the args include `--nocert` or `--tlscertpath`
      else if useCertPathCmd then ''''${certPath:+--tlscertpath="$certPath"}''
      else if certPath != null then "--tlscertpath='${certPath}'"
      else "--nocert";
  in
  # TODO-EXTERNAL:
  # lndconnect requires a --configfile argument, although it's unused
  # https://github.com/LN-Zap/lndconnect/issues/25
  lib.hiPrio (pkgs.writeScriptBin name ''
    ${shebang}
    ${optionalString enableOnion ''
      # Never run lndconnect without a host. It then asks public services for
      # the node's IP over clearnet and prints a URL with that IP.
      # lndconnect uses the last `--host`, so a host in the args replaces the
      # onion address.
      host=
      prevArg=
      for arg; do
        # Like lndconnect, take no args after `--` as options
        if [[ $arg == -- ]]; then
          break
        fi
        if [[ $prevArg == --host || $arg == --host=* ]]; then
          host=''${arg#--host=}
          # lndconnect removes the double quotes around a value, so `""` is empty too
          if [[ ! $host || $host == '""' ]]; then
            echo "Error: --host needs a value" >&2
            exit 1
          fi
        fi
        prevArg=$arg
      done
      if [[ ! $host ]]; then
        onionFile=${onionFile}
        if ! host=$(cat "$onionFile") || [[ ! $host =~ ^[a-z2-7]{56}\.onion$ ]]; then
          {
            echo "Error: Can't read an onion address from $onionFile"
            echo "Tor or the onion-addresses service may not have started yet. Check them with"
            echo "'systemctl status tor onion-addresses'."
            echo "Or user $(id -un) has no access to this onion address. See option"
            echo "'nix-bitcoin.onionAddresses.access'."
          } >&2
          exit 1
        fi
      fi
    ''}
    ${optionalString checkOwner ''
      readOwned() {
        local content
        if [[ -f $1 ]] && content=$(
             { [[ -f /dev/stdin && $(stat -L -c %U /dev/stdin) == ${escapeShellArg secretsOwner} ]] &&
               head -c 65536; } < "$1"
           ); then
          printf '%s\n' "$content"
        else
          echo "Error: '$1' isn't a regular file of user ${secretsOwner}" >&2
          return 1
        fi
      }
      auth=$(readOwned '${authSecretPath}')
    ''}
    ${optionalString useCertPathCmd ''
      certPath=
      needsCertPath=1
      for arg; do
        case $arg in
          --nocert|--tlscertpath|--tlscertpath=*) needsCertPath= ;;
        esac
      done
      if [[ $needsCertPath ]]; then
        certPath=$(${getCertPathCmd}) || exit
        ${optionalString checkOwner ''
          cert=$(readOwned "$certPath")
          certPath=/dev/fd/4
        ''}
      fi
    ''}
    url=$(
      ${getExe config.nix-bitcoin.pkgs.lndconnect} --url \
        ${optionalString enableOnion ''--host="$host"''} \
        --port=${toString port} \
        ${certArg} \
        --adminmacaroonpath=${if checkOwner then "/dev/fd/3" else "'${authSecretPath}'"} \
        --configfile=/dev/null "$@" \
        ${optionalString checkOwner ''3<<< "$auth" 4<<< "''${cert-}"''}
    )

    ${optionalString isClnrest
      # Change URL protocol to clnrest and replace the macaroon with a rune.
      ''
        rune=${if checkOwner then "$auth" else "$(cat '${authSecretPath}')"}
        # Bash substitution keeps the rune out of process arguments, which
        # every local user can read through /proc/<pid>/cmdline.
        url=''${url/#lndconnect/clnrest}
        url=''${url/macaroon=*/rune=$rune}
      ''
     }

    # If --url is in args
    if [[ " $* " =~ " --url " ]]; then
      echo "$url"
    else
      # This UTF-8 encoding yields a smaller, more convenient output format
      # compared to the native lndconnect output
      echo -n "$url" | ${getExe pkgs.qrencode} -t UTF8 -o -
    fi
  '');

  # Like onion-services.nix, give the operator onion access only when the
  # operator role is enabled, so that access stays an explicit choice
  operator = config.nix-bitcoin.operator;
  operatorName = operator.name;
in {
  inherit options;

  config = mkMerge [
    (mkIf (lnd.enable && lnd.lndconnect.enable)
      (mkMerge [
        {
          environment.systemPackages = [(
            mkLndconnect {
              name = "lndconnect";
              # Run as lnd user because the macaroon and cert are not group-readable
              shebang = "#!/usr/bin/env -S ${runAsUser} ${lnd.user} ${pkgs.bash}/bin/bash";
              enableOnion = lnd.lndconnect.onion;
              onionService = "${lnd.user}/lnd-rest";
              port = lnd.restPort;
              certPath = lnd.certPath;
              authSecretPath = "${lnd.networkDir}/admin.macaroon";
            }
          )];

          # Don't change `lnd.restAddress`. Exposing the REST API must be an explicit choice.
        }

        (mkIf lnd.lndconnect.onion {
          services.tor = {
            enable = true;
            relay.onionServices.lnd-rest = nbLib.mkOnionService {
              target.addr = nbLib.address lnd.restAddress;
              target.port = lnd.restPort;
              port = lnd.restPort;
            };
          };
          # Two definitions, so that `operatorName == lnd.user` is not a duplicate key
          nix-bitcoin.onionAddresses.access = mkMerge [
            { ${lnd.user} = [ "lnd-rest" ]; }
            (mkIf operator.enable { ${operatorName} = [ "lnd-rest" ]; })
          ];
        })
      ]))

    (mkIf (clnrest.enable && clnrest.lnconnect.enable)
      (mkMerge [
        {
          environment.systemPackages = [(
            mkLndconnect {
              name = "lnconnect-clnrest";
              # Root runs it as the clightning user, which owns the admin rune and
              # clnrest's cert, like lndconnect runs as the lnd user
              shebang = "#!/usr/bin/env -S ${nbLib.runAsUserIfRoot clightning.user} ${pkgs.stdenv.shell} -e";
              isClnrest = true;
              secretsOwner = clightning.user;
              enableOnion = clnrest.lnconnect.onion;
              userOnionService = "clnrest";
              port = clnrest.port;
              # Ask clightning for clnrest's cert dir, which `clnrest-certs` can change.
              # The query fails when clightning is down, or when the caller can't read
              # a config file that lightning-cli reads, for example an include file.
              # Then use the default dir, as before.
              getCertPathCmd = let
                defaultCert = "${clightning.networkDir}/server.pem";
              in ''
                if ! response=$(${clightning.cli}/bin/lightning-cli listconfigs clnrest-certs) ||
                   ! ${clnrest.serverCertPathFromConfigs} <<< "$response"; then
                  {
                    echo "Warning: Can't ask clightning for clnrest's cert dir''${response:+: $response}"
                    echo "Warning: The URL has the cert from the default dir: ${defaultCert}"
                    echo "Warning: With clnrest-certs set, run this while clightning runs or pass --tlscertpath."
                  } >&2
                  echo '${defaultCert}'
                fi
              '';
              authSecretPath = "${clightning.networkDir}/admin-rune";
            }
          )];

          # Don't change `clnrest.address`. Exposing the REST API must be an explicit choice.
        }

        (mkIf clnrest.lnconnect.onion {
          services.tor = {
            enable = true;
            relay.onionServices.clnrest = nbLib.mkOnionService {
              target.addr = nbLib.address clnrest.address;
              target.port = clnrest.port;
              port = clnrest.port;
            };
          };
          # The operator's copy also allows nodeinfo to show the clnrest onion address.
          # Two definitions, so that `operatorName == clightning.user` is not a duplicate key
          nix-bitcoin.onionAddresses.access = mkMerge [
            # Without clightning, its user doesn't exist
            (mkIf clightning.enable { ${clightning.user} = [ "clnrest" ]; })
            (mkIf operator.enable { ${operatorName} = [ "clnrest" ]; })
          ];
        })
      ])
    )
  ];
}
