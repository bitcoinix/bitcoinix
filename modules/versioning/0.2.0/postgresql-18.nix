{ config, options, lib, ... }:

let
  cfg = config.services.postgresql;
  # The unversioned `pkgs.postgresql` moves from 17 to 18. It can't be told
  # apart from `pkgs.postgresql_18`, so report every package set to 18.
  schema = builtins.tryEval cfg.package.psqlSchema;
  # Read the priority only when the package evaluates: a definition that
  # throws also throws here.
  isSet = options.services.postgresql.package.highestPrio < (lib.mkDefault null).priority;
in
{
  condition = cfg.enable && schema.success && schema.value == "18" && isSet;
  message = ''
    nixos-unstable's `pkgs.postgresql` has moved from PostgreSQL 17 to 18, and your
    `services.postgresql.package` selects PostgreSQL 18. If your server still runs
    PostgreSQL 17, PostgreSQL 18 doesn't use its data: it starts with a new, empty
    data dir or, with a custom `services.postgresql.dataDir`, fails to start.
    Check the running version as root with
    `runuser -u postgres -- psql -tAc 'SHOW server_version'`. To keep PostgreSQL 17,
    set `services.postgresql.package = pkgs.postgresql_17;` before you update.
  '';
}
