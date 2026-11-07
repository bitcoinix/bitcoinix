{ config, lib, pkgs, ... }:

with lib;
let
  options = {
    services.clightning.plugins.clnrest = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable clnrest (Core Lightning plugin).

          clnrest provides a Core Lightning REST API, using Core Lightning RPC calls as its backend.
          It also broadcasts Core Lightning notifications to listeners connected to its websocket server.

          See here for all available options:
          https://docs.corelightning.org/docs/rest
          Extra options can be set via `services.clightning.extraConfig`.
        '';
      };
      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address to listen for REST connections.";
      };
      port = mkOption {
        type = types.port;
        default = 3010;
        description = "REST server port.";
      };
      createAdminRune = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Create a rune with admin permissions at path `''${config.services.clightning.networkDir}/admin-rune`.
        '';
      };
      package = mkOption {
        type = types.package;
        default = config.nix-bitcoin.pkgs.clightning-plugins.clnrest;
        defaultText = "config.nix-bitcoin.pkgs.clightning-plugins.clnrest";
        description = "The package providing clnrest binaries.";
      };
    };

    # Internal read-only options used by `./nodeinfo.nix` and `./onion-services.nix`
    services.clnrest = let
      inherit (config.nix-bitcoin.lib) mkAlias;
    in {
      enable = mkAlias cfg.enable;
      address = mkAlias cfg.address;
      port = mkAlias cfg.port;
    };
  };

  cfg = config.services.clightning.plugins.clnrest;
  nbLib = config.nix-bitcoin.lib;
  inherit (config.services) clightning;

  runePath = "${clightning.networkDir}/admin-rune";
in
{
  inherit options;

  config = mkIf cfg.enable {
    services.clightning.pluginsConfig = ''
      plugin=${lib.getExe cfg.package}
      clnrest-host=${cfg.address}
      clnrest-port=${toString cfg.port}
    '';

    systemd.services.clightning.postStart = mkAfter (
      optionalString cfg.createAdminRune ''
        runeFile='${runePath}'
        # Earlier versions installed an empty or `null` rune when `createrune`
        # failed. Replace such a file like a missing one, but keep any other file.
        if [[ ! -e $runeFile ]] ||
           [[ -f $runeFile && -r $runeFile && $(< "$runeFile") =~ ^(null)?$ ]]; then
          # Fail the start instead of installing a bad rune.
          # `Restart=on-failure` then tries again.
          if ! response=$(${clightning.cli}/bin/lightning-cli createrune) ||
             ! rune=$(${pkgs.jq}/bin/jq -er .rune <<< "$response") || [[ ! $rune ]]; then
            echo "Error: Can't create the admin rune: $response" >&2
            exit 1
          fi
          # Replace the file in one step, so that a crash can't leave a partial rune
          install -T -m 640 <(echo "$rune") "$runeFile.tmp"
          mv -fT "$runeFile.tmp" "$runeFile"
        fi
      '' +
      # Wait until the clnrest server is listening.
      # Usually, the server is already listening at this point.
      # But when clnrest is running for the first time, certificates are generated
      # before the server starts, which can take a few seconds.
      ''
        while ! { exec 3>/dev/tcp/${nbLib.address cfg.address}/${toString cfg.port}; } &>/dev/null; do
          sleep 0.1
        done
      ''
    );
  };
}
