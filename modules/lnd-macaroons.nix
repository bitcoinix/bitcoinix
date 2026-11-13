{ config, lib, pkgs, ... }:

# Custom lnd macaroons, created by lnd-create-macaroons each time lnd starts.
#
# Each macaroon has its own root key, so that changing or removing the
# macaroon revokes its old copies. The root key IDs are tagged "nb" (0x6e62)
# in their top 16 bits. lnd-create-macaroons deletes every root key in this
# range that no configured macaroon uses.

with lib;
let
  options.services.lnd.macaroons = mkOption {
    default = {};
    type = with types; attrsOf (submodule ({ name, config, ... }: {
      options = {
        user = mkOption {
          type = types.str;
          description = "User who owns the macaroon.";
        };
        permissions = mkOption {
          type = types.str;
          example = ''
            {"entity":"info","action":"read"},{"entity":"onchain","action":"read"}
          '';
          description = "List of granted macaroon permissions.";
        };
        rootKeyId = mkOption {
          type = types.str;
          readOnly = true;
          default = macaroonRootKeyId name config;
          defaultText = literalMD "Derived from the name, user and permissions";
          description = ''
            The ID of the macaroon's own lnd root key.
            A change of the name, user or permissions gives a new ID,
            which revokes the copies of the previous macaroon.
          '';
        };
      };
    }));
    description = ''
      Extra macaroons, created at {file}`/run/lnd/<name>.macaroon` when lnd starts.
    '';
  };

  cfg = config.services.lnd;
  nbLib = config.nix-bitcoin.lib;

  macaroonIdTag = "6e62";
  macaroonIdRange = {
    first = toString (fromHexString "${macaroonIdTag}000000000000");
    last = toString (fromHexString "${macaroonIdTag}ffffffffffff");
  };

  # Sorted and without duplicates, so that equivalent definitions get the same ID.
  # null unless the permissions are a non-empty list of {entity, action} strings.
  # lncli takes them as `entity:action`, so neither may contain a colon.
  canonicalPermissions = permissions: let
    parsed = builtins.fromJSON "[${permissions}]";
    isPermission = p: isAttrs p && attrNames p == [ "action" "entity" ]
      && isString p.entity && isString p.action && !hasInfix ":" (p.entity + p.action);
    before = a: b: if a.entity == b.entity then a.action < b.action else a.entity < b.entity;
  in if parsed != [] && all isPermission parsed then sort before (unique parsed) else null;

  # The same definition keeps its ID, so lnd reuses its root key and the copies
  # stay valid across restarts. IDs carry 48 bits of the hash, so two definitions
  # can be crafted to collide, but only by whoever writes both of them.
  macaroonRootKeyId = name: { user, permissions, ... }: let
    hash = builtins.hashString "sha256" (concatStringsSep "\n" [
      "bitcoinix-macaroon-v1" name user (builtins.toJSON (canonicalPermissions permissions))
    ]);
  in toString (fromHexString (macaroonIdTag + substring 0 12 hash));
  rootKeyIds = mapAttrsToList (_: macaroon: macaroon.rootKeyId) cfg.macaroons;

  jq = "${pkgs.jq}/bin/jq";
  runuser = "${pkgs.util-linux}/bin/runuser";
  # Where lncli looks for profiles: the lnd user's home from the passwd entry
  lncliDir = "${config.users.users.${cfg.user}.home}/.lncli";
  systemctl = "${config.systemd.package}/bin/systemctl";
  # lnd.nix adds rpcAddress to the certificate, also when it's 0.0.0.0 or ::
  # An IPv6 rpcAddress may be given with or without brackets.
  rpcServer = let
    bare = removePrefix "[" (removeSuffix "]" cfg.rpcAddress);
    address = if hasInfix ":" bare then "[${bare}]" else bare;
  in "${address}:${toString cfg.rpcPort}";

  # Restarts lnd after deleting stale root keys, unless lnd was stopped meanwhile.
  # `--job-mode=fail` keeps a queued stop from being replaced by the restart.
  # Fail closed: if the restart fails while the old lnd process still runs, stop
  # lnd, as the streams opened with the deleted root keys may still be open.
  # Each start gives lnd a new InvocationID, so the old process still runs if lnd
  # is active with the ID from before the restart. Otherwise the old process is
  # gone, for example when only the new start failed. Then `Restart=` starts lnd
  # again, and a stop would cancel that.
  restartLnd = nbLib.script "lnd-restart-after-macaroon-cleanup" ''
    invocation=$(${systemctl} show -P InvocationID lnd.service)
    if ! ${systemctl} try-restart --job-mode=fail lnd.service; then
      if [[ $(${systemctl} show -P InvocationID lnd.service) == "$invocation" ]] &&
        ${systemctl} is-active --quiet lnd.service; then
        echo "Failed to restart lnd after deleting macaroon root keys. Stop lnd." >&2
        ${systemctl} stop lnd.service
      else
        echo "Failed to restart lnd after deleting macaroon root keys." \
          "The old lnd process was stopped." >&2
      fi
      exit 1
    fi
  '';

  # Runs as the lnd user. Creates an lncli profile file without profiles if there
  # is none or it's empty, for example after a crash. lncli parses the file also
  # with an empty --profile, and an empty file makes it fail. Leave a non-empty
  # file alone: the lnd user owns it.
  createProfileFile = nbLib.script "lncli-create-profile-file" ''
    dir=${escapeShellArg lncliDir}
    umask 077
    [[ -s $dir/profiles.json ]] || { mkdir -p "$dir" && echo "{}" > "$dir/profiles.json"; }
  '';

  # This script runs as root, because setting the macaroon owners needs root.
  # The lnd data dir and $RUNTIME_DIRECTORY are writable by the lnd user, which
  # could place symlinks there. So never read or write files as root via paths
  # in these dirs:
  # - Run lncli as the lnd user. It reads the admin macaroon itself.
  #   Its output is controlled by lnd: limit its size and validate it.
  # - Create the macaroons in a root-only dir and move them to
  #   $RUNTIME_DIRECTORY via rename (`mv -T`), which doesn't follow symlinks.
  #   Renaming requires both dirs to be on the same filesystem (`/run`).
  createMacaroons = nbLib.rootScript "lnd-create-macaroons" ''
    tmpDir=$(mktemp -d /run/lnd-macaroons.XXXXXX)
    trap 'rm -rf "$tmpDir"' EXIT
    umask ug=r,o=

    # lncli prefers a default profile in ~/.lncli over its flags, and the lnd
    # user owns its home. An empty --profile turns profiles off, but lncli
    # accepts it only when the profile file exists. If lnd deletes the file
    # in between, lncli fails.
    ${runuser} -u ${cfg.user} -- ${createProfileFile}
    lncli() {
      ${runuser} -u ${cfg.user} -- ${cfg.package}/bin/lncli --profile= \
        --rpcserver ${escapeShellArg rpcServer} --tlscertpath '${cfg.certPath}' \
        --macaroonpath '${cfg.networkDir}/admin.macaroon' "$@"
    }
    # A larger size limit, so that many root keys don't block the start
    staleIds() {
      lncli listmacaroonids | head -c 1048576 |
        ${jq} -nr -f ${./lnd-macaroons/stale-ids.jq} \
          --arg first ${macaroonIdRange.first} --arg last ${macaroonIdRange.last} \
          --argjson current ${escapeShellArg (builtins.toJSON rootKeyIds)}
    }

    # Revoke all copies of macaroons that are no longer configured
    stale=$(staleIds)
    if [[ $stale ]]; then
      for id in $stale; do
        echo "Delete the root key of stale macaroon ID $id"
        lncli deletemacaroonid "$id" | head -c 65536 |
          ${jq} -se -f ${./lnd-macaroons/deleted.jq} >/dev/null
      done
      remaining=$(staleIds)
      if [[ $remaining ]]; then
        echo "lnd didn't delete the root keys of stale macaroon IDs:" "$remaining" >&2
        exit 1
      fi
    fi

    # Usage: bake <name> <user> <root key ID> <entity:action>...
    bake() {
      local name=$1 user=$2 id=$3 hex
      shift 3
      local tmpMacaroon="$tmpDir/$name.macaroon"
      echo "Create custom macaroon $name with root key ID $id"
      hex=$(lncli bakemacaroon --root_key_id "$id" "$@" | head -c 65536)
      if [[ ! $hex =~ ^[0-9a-f]+$ ]]; then
        echo "lncli didn't print a macaroon for $name" >&2
        exit 1
      fi
      printf '%s' "$hex" | ${pkgs.xxd}/bin/xxd -p -r > "$tmpMacaroon"
      # Check what lnd baked. printmacaroon decodes the file locally and
      # doesn't print the macaroon itself.
      if ! ${cfg.package}/bin/lncli printmacaroon --macaroon_file "$tmpMacaroon" |
        ${jq} -e --arg id "$id" \
          '.root_key_id == $id and (.permissions | unique) == ($ARGS.positional | unique)' \
          --args "$@" >/dev/null
      then
        echo "Macaroon $name doesn't have root key ID $id and the configured permissions" >&2
        exit 1
      fi
      chown "$user": "$tmpMacaroon"
      mv -fT "$tmpMacaroon" "$RUNTIME_DIRECTORY/$name.macaroon"
    }
    ${concatStrings (mapAttrsToList (name: macaroon: ''
      bake ${escapeShellArgs ([ name macaroon.user macaroon.rootKeyId ]
        ++ map (p: "${p.entity}:${p.action}") (canonicalPermissions macaroon.permissions))}
    '') cfg.macaroons)}
    # Deleting a root key doesn't close the streams that were opened with it.
    # Restart lnd once to close them. The next start finds no stale IDs.
    # Restart after this start has finished, as a restart during it would kill
    # this script and fail the start.
    if [[ $stale ]]; then
      echo "Restart lnd to close the connections of deleted macaroons"
      ${config.systemd.package}/bin/systemd-run --no-block --quiet --collect \
        --description="Restart lnd after deleting macaroon root keys" \
        --property=After=lnd.service ${restartLnd}
    fi
  '';
in {
  inherit options;

  config = mkIf cfg.enable {
    assertions = [
      { assertion = allUnique rootKeyIds;
        message = "Two macaroons in services.lnd.macaroons have the same root key ID. Rename one of them.";
      }
    ] ++ concatLists (mapAttrsToList (name: macaroon: [
      { # The name is part of file names: `<name>.macaroon` must fit 255 bytes
        assertion = builtins.match "[A-Za-z0-9_-][A-Za-z0-9._-]*" name != null
          && stringLength name <= 246;
        message = ''
          The name of services.lnd.macaroons.${name} may only contain letters, digits,
          `.`, `_` and `-`, must not start with `.` and may have at most 246 characters.
        '';
      }
      { assertion = canonicalPermissions macaroon.permissions != null;
        message = ''
          services.lnd.macaroons.${name}.permissions must be a non-empty, comma-separated
          list of objects like {"entity":"info","action":"read"}, with exactly these two
          fields, both strings without a colon.
        '';
      }
    ]) cfg.macaroons);

    systemd.services.lnd.serviceConfig = {
      RuntimeDirectory = "lnd"; # Only used to store custom macaroons
      RuntimeDirectoryMode = "711";
      # Keep the macaroons while lnd restarts, as services may read them then
      RuntimeDirectoryPreserve = "restart";
      ExecStartPost = [ createMacaroons ];
    };
  };
}
