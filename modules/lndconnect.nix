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

    bitcoinix.mkLndconnect = mkOption {
      readOnly = true;
      default = mkLndconnect;
      description = ''
        A function to create a lndconnect binary.
        See the source for further details.
      '';
    };
  };

  nbLib = config.bitcoinix.lib;
  runAsUser = config.bitcoinix.runAsUserCmd;

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
    certPath ? null,
    # Instead of `certPath`: Bash code that prints the cert path.
    # It runs only when the URL includes the cert and the args don't set
    # `--tlscertpath`.
    getCertPathCmd ? null
  }:
  let
    useCertPathCmd = getCertPathCmd != null && !enableOnion;
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
      fi
    ''}
    url=$(
      ${getExe config.bitcoinix.pkgs.lndconnect} --url \
        ${optionalString enableOnion "--host=\"$(cat '${config.bitcoinix.onionAddresses.dataDir}/${onionService}')\""} \
        --port=${toString port} \
        ${certArg} \
        --adminmacaroonpath='${authSecretPath}' \
        --configfile=/dev/null "$@"
    )

    ${optionalString isClnrest
      # Change URL protocol to clnrest and replace the macaroon with a rune.
      ''
        rune=$(cat '${authSecretPath}')
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
  operator = config.bitcoinix.operator;
  operatorName = operator.name;
  # This is also true when a config grants the access explicitly
  operatorHasClnrestAccess =
    elem "clnrest" (config.bitcoinix.onionAddresses.access.${operatorName} or []);
  # The `users.users` attribute that defines the operator's login, which can
  # differ from the login name. null if no enabled account has that name.
  operatorAccount = findFirst (key:
    let u = config.users.users.${key}; in u.name == operatorName && (u.enable or true)
  ) null (attrNames config.users.users);
  operatorExists = operatorAccount != null;
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
          bitcoinix.onionAddresses.access = mkMerge [
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
              isClnrest = true;
              enableOnion = clnrest.lnconnect.onion;
              onionService = "${operatorName}/clnrest";
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
          assertions = [
            { assertion = operatorHasClnrestAccess;
              message = ''
                `services.clightning.plugins.clnrest.lnconnect.onion` requires that the
                operator user `${operatorName}` can read the clnrest onion address, because
                `lnconnect-clnrest` reads it from that user's directory.
                Set `bitcoinix.operator.enable = true`.
              '' + (if operatorExists then ''
                Or add "clnrest" to `bitcoinix.onionAddresses.access.${operatorName}`.
                To run `lnconnect-clnrest` as `${operatorName}` instead of root, also add
                "${clightning.group}" to `users.users.${operatorAccount}.extraGroups`. That group
                can read the admin rune and use the clightning RPC socket.
              '' else ''
                Or define the user `${operatorName}` and grant the access explicitly,
                see docs/services.md.
              '');
            }
          ];
          services.tor = {
            enable = true;
            relay.onionServices.clnrest = nbLib.mkOnionService {
              target.addr = nbLib.address clnrest.address;
              target.port = clnrest.port;
              port = clnrest.port;
            };
          };
          # This also allows nodeinfo to show the clnrest onion address
          bitcoinix.onionAddresses.access = mkIf operator.enable { ${operatorName} = [ "clnrest" ]; };
        })
      ])
    )
  ];
}
