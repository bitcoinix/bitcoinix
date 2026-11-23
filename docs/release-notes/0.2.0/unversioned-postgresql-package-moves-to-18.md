#### Unversioned PostgreSQL package moves to 18

nixos-unstable's `pkgs.postgresql` has moved from PostgreSQL 17 to 18. If you set
`services.postgresql.package = pkgs.postgresql;` and run PostgreSQL 17, set
`pkgs.postgresql_17` before you update, see the
[upgrade notes](../../upgrading/0.2.0/unversioned-postgresql-package-moves-to-18.md).
