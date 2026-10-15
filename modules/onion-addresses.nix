# This module enables unprivileged users to read onion addresses.
# By default, onion addresses in /var/lib/tor/onion are only readable by the
# tor user.
# The included service copies onion addresses to /var/lib/onion-addresses/<user>/
# and sets permissions according to option 'access'.

{ config, lib, pkgs, ... }:

with lib;
let
  options.nix-bitcoin.onionAddresses = {
    access = mkOption {
      type = with types; attrsOf (listOf str);
      default = {};
      description = ''
        This option controls who is allowed to access onion addresses.
        For example, the following allows user 'myuser' to access bitcoind
        and clightning onion addresses:
        ```nix
        {
          "myuser" = [ "bitcoind" "clightning" ];
        };
        ```
        The onion hostnames can then be read from
        {file}`/var/lib/onion-addresses/myuser`.
      '';
    };
    services = mkOption {
      type = with types; listOf str;
      default = [];
      description = ''
        Services that can access their onion address via file
        {file}`/var/lib/onion-addresses/<service>`
        The file is readable only by the service user.
      '';
    };
    dataDir = mkOption {
      readOnly = true;
      default = "/var/lib/onion-addresses";
    };
  };

  cfg = config.nix-bitcoin.onionAddresses;
  nbLib = config.nix-bitcoin.lib;
in {
  inherit options;

  config = mkIf (cfg.access != {} || cfg.services != []) {
    systemd.services.onion-addresses = {
      wantedBy = [ "tor.service" ];
      bindsTo = [ "tor.service" ];
      after = [ "tor.service" ];
      serviceConfig = nbLib.defaultHardening // {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "onion-addresses";
        StateDirectoryMode = "771";
        PrivateNetwork = true; # This service needs no network access
        PrivateUsers = false;
        # CAP_SETUID/CAP_SETGID: Read the Tor hostname files as user tor
        CapabilityBoundingSet = "CAP_CHOWN CAP_FSETID CAP_SETFCAP CAP_DAC_OVERRIDE CAP_DAC_READ_SEARCH CAP_FOWNER CAP_IPC_OWNER CAP_SETUID CAP_SETGID";
      };
      # This script runs as root, but the per-user dirs are owned by their users
      # and the Tor hostname dirs are writable by user tor. These users could
      # place symlinks there, so never read or write files as root via paths in
      # these dirs:
      # - Read the hostname files as user tor.
      # - Create the output in a root-only staging dir and only then move it to
      #   the data dir via rename (`mv -T`), which doesn't follow symlinks.
      #   Renaming requires both dirs to be on the same filesystem, so the
      #   staging dir is located in the data dir, which is not writable by users.
      #
      # The hostname file content is spliced into config files
      # (`externalip=$(cat ...)` in bitcoin.conf and lnd.conf, `announce-addr=`
      # for clightning). So only accept exactly one v3 onion address.
      # Invalid files are skipped and the service fails after writing the
      # remaining addresses.
      script = ''
        waitForFile() {
          file=$1
          for ((i=0; i<300; i++)); do
            if [[ -e $file ]]; then
              return;
            fi
            sleep 0.1
          done
          echo "Error: File $file did not appear after 30 sec." >&2
          exit 1
        }

        readOnionAddress() {
          local file=/var/lib/tor/onion/$1/hostname content
          waitForFile "$file"
          # Append `x` to keep trailing newlines, which `$(...)` would strip
          if ! content=$(${pkgs.util-linux}/bin/setpriv --reuid=tor --regid=tor --clear-groups -- \
                           head -c 100 -- "$file" && echo x); then
            echo "Error: Can't read $file as user tor" >&2
            return 1
          fi
          content=''${content%x}
          if [[ ! $content =~ ^[a-z2-7]{56}\.onion$'\n'?$ ]]; then
            echo "Error: $file doesn't contain exactly one v3 onion address" >&2
            return 1
          fi
          echo "''${content%$'\n'}"
        }

        failed=
        writeOnionAddress() {
          local service=$1 dest=$2 owner=$3 mode=$4 address
          if address=$(readOnionAddress "$service"); then
            echo "$address" > "$dest"
            chown "$owner" "$dest"
            chmod "$mode" "$dest"
          else
            echo "Error: Skipping onion address of service $service for $owner" >&2
            failed=1
          fi
        }

        # Wait until tor is up
        waitForFile /var/lib/tor/state

        cd ${cfg.dataDir}
        # Remove leftovers of previous runs
        rm -rf -- ./.staging.* ./.trash.* || echo "Warning: Can't remove leftover dirs" >&2
        staging=$(mktemp -d ./.staging.XXXXXX)
        trap 'rm -rf -- "$staging"' EXIT

        ${concatMapStrings
          (user: ''
            mkdir -m 0700 "$staging/${user}"
            ${concatMapStrings
              (service: ''
                writeOnionAddress '${service}' "$staging/${user}/${service}" '${user}' 600
              '')
              cfg.access.${user}
             }
            chown '${user}' "$staging/${user}"
          '')
          (builtins.attrNames cfg.access)
        }

        ${optionalString (cfg.services != []) ''
          mkdir -m 0755 "$staging/services"
          ${concatMapStrings (service: ''
            writeOnionAddress '${service}' "$staging/services/${service}" '${config.systemd.services.${service}.serviceConfig.User}' 400
          '') cfg.services}
        ''}

        # Move the old entries to a root-only dir instead of deleting them in place.
        # Deleting recurses into user-owned dirs and can be made to fail by the
        # user, which would leave all addresses missing.
        trash=$(mktemp -d ./.trash.XXXXXX)
        for entry in *; do
          if [[ -e $entry || -L $entry ]]; then
            mv -T -- "$entry" "$trash/$entry"
          fi
        done
        ${concatMapStrings (entry: ''
          mv -T "$staging/${entry}" '${entry}'
        '') (builtins.attrNames cfg.access ++ optional (cfg.services != []) "services")}
        rm -rf -- "$trash" || echo "Warning: Can't remove $trash" >&2

        if [[ $failed ]]; then
          exit 1
        fi
      '';
    };
  };
}
