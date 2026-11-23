#### Unversioned PostgreSQL package moves to 18

nixos-unstable's `pkgs.postgresql` has moved from PostgreSQL 17 to 18. If you set
`services.postgresql.package = pkgs.postgresql;`, PostgreSQL 18 doesn't use your
PostgreSQL 17 data after the update: it starts with a new, empty data dir
`/var/lib/postgresql/18` or, with a custom `services.postgresql.dataDir`, fails to
start. Evaluation reports each config that sets a PostgreSQL 18 package.

Check the running version as root with
`runuser -u postgres -- psql -tAc 'SHOW server_version'`. If it's 17, set
`services.postgresql.package = pkgs.postgresql_17;` before you update. To move to
PostgreSQL 18 later, follow the steps in
[PostgreSQL 14 removed](postgresql-14-removed.md) with `pkgs.postgresql_18` in place of
`pkgs.postgresql_17`.
