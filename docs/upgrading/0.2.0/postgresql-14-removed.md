#### PostgreSQL 14 removed

nixos-unstable has removed PostgreSQL 14. If you don't set `services.postgresql.package`,
NixOS selects PostgreSQL by `system.stateVersion`, and with a `stateVersion` from 22.05
through 23.05 that was PostgreSQL 14. Then your PostgreSQL databases, such as those of
BTCPay Server and NBXplorer, are in PostgreSQL 14, and bitcoinix 0.2.0 fails evaluation.
This also happens if you set `services.postgresql.package = pkgs.postgresql_14;`.
Check the running version as root with
`runuser -u postgres -- psql -tAc 'SHOW server_version'`.

Upgrade the databases before you update bitcoinix, while the node still has
PostgreSQL 14. The steps follow
[Upgrading](https://nixos.org/manual/nixos/stable/#module-services-postgres-upgrading)
in the NixOS manual, but run the commands as root with `runuser`, which works without
`sudo`. With the secure-node preset, `sudo` is only an alias for `doas`.

1. Back up the databases, see [Backups](../../services.md#backups).
2. Add this to your configuration and deploy it with your current bitcoinix version:

   ```nix
   environment.systemPackages = [
     (let
       cfg = config.services.postgresql;
       newPostgres = pkgs.postgresql_17.withPackages cfg.extensions;
       newData = "/var/lib/postgresql/${newPostgres.psqlSchema}";
       # Add the other services that use PostgreSQL
       units = lib.optionals config.services.btcpayserver.enable [
         "btcpayserver" "nbxplorer"
       ] ++ [ "postgresql" ];
       # initdb turns data checksums off by default before PostgreSQL 18,
       # which added this flag and turns them on
       noChecksums = lib.optionalString (lib.versionAtLeast newPostgres.psqlSchema "18")
         "--no-data-checksums";
     in pkgs.writeScriptBin "upgrade-pg-cluster" ''
       set -eux
       export NEWDATA="${newData}"
       export NEWBIN="${newPostgres}/bin"
       export OLDDATA="${cfg.dataDir}"
       export OLDBIN="${cfg.finalPackage}/bin"
       if [ -e "$NEWDATA" ]; then
         echo "$NEWDATA exists. Leave it intact and set newData to a new dir." >&2
         exit 1
       fi
       # pg_upgrade requires the new cluster to match the old data checksum setting
       case $(runuser -u postgres -- "$OLDBIN/psql" -p ${toString cfg.settings.port} -tAc 'SHOW data_checksums') in
         on) checksums=--data-checksums ;;
         off) checksums="${noChecksums}" ;;
         *) echo "Can't read data_checksums. Is PostgreSQL running?" >&2; exit 1 ;;
       esac
       systemctl stop ${toString units}
       trap 'systemctl start ${toString units}' ERR
       install -d -m 0700 -o postgres -g postgres "$NEWDATA"
       cd "$NEWDATA"
       runuser -u postgres -- "$NEWBIN/initdb" -D "$NEWDATA" ${lib.escapeShellArgs cfg.initdbArgs} $checksums
       runuser -u postgres -- "$NEWBIN/pg_upgrade" \
         --old-datadir "$OLDDATA" --new-datadir "$NEWDATA" \
         --old-bindir "$OLDBIN" --new-bindir "$NEWBIN" \
         "$@"
     '')
   ];
   ```

   If you set `services.postgresql.dataDir`, set `newData` to a path that doesn't
   exist yet. If you set `services.postgresql.extensions` to a list, write it as a
   function, such as `ps: [ ps.postgis ]`, so that the script uses the PostgreSQL 17
   extensions. The script initializes the new data dir with the data checksum
   setting of the running server, as `pg_upgrade` requires.
3. Run `upgrade-pg-cluster` as root. If `newData` already exists, the script stops
   before it changes anything. Don't delete that dir, it can hold another cluster:
   set `newData` to a new path. If the script fails later, it starts the services
   again on the old data, which it leaves unchanged. Fix the cause and delete the
   `newData` dir that the script created before you run it again.
4. Set `services.postgresql.package = pkgs.postgresql_17;` and, if you set it,
   `services.postgresql.dataDir` to `newData`. Remove the script and deploy.
   PostgreSQL and its services start on the upgraded data.
5. Check BTCPay Server, then update bitcoinix.

Don't change `system.stateVersion` to select a newer PostgreSQL: the data dir
`/var/lib/postgresql/<version>` changes with it, so PostgreSQL starts with a new,
empty database.
