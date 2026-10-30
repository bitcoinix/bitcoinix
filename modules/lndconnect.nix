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
    certPath ? null
  }:
  # TODO-EXTERNAL:
  # lndconnect requires a --configfile argument, although it's unused
  # https://github.com/LN-Zap/lndconnect/issues/25
  lib.hiPrio (pkgs.writeScriptBin name ''
    ${shebang}
    url=$(
      ${getExe config.nix-bitcoin.pkgs.lndconnect} --url \
        ${optionalString enableOnion "--host=\"$(cat '${config.nix-bitcoin.onionAddresses.dataDir}/${onionService}')\""} \
        --port=${toString port} \
        ${if enableOnion || certPath == null then "--nocert" else "--tlscertpath='${certPath}'"} \
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
  operator = config.nix-bitcoin.operator;
  operatorName = operator.name;
  # This is also true when a config grants the access explicitly
  operatorHasClnrestAccess =
    elem "clnrest" (config.nix-bitcoin.onionAddresses.access.${operatorName} or []);
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
              isClnrest = true;
              enableOnion = clnrest.lnconnect.onion;
              onionService = "${operatorName}/clnrest";
              port = clnrest.port;
              certPath = "${clightning.networkDir}/server.pem";
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
                Set `nix-bitcoin.operator.enable = true`, or add "clnrest" to
                `nix-bitcoin.onionAddresses.access.${operatorName}`.
              '';
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
          nix-bitcoin.onionAddresses.access = mkIf operator.enable { ${operatorName} = [ "clnrest" ]; };
        })
      ])
    )
  ];
}
