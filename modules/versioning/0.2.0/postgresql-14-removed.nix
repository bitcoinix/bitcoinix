{ config, options, lib, ... }:

let
  cfg = config.services.postgresql;
  stateVersion = config.system.stateVersion;
  # nixpkgs replaced postgresql_14 with a throwing alias. Catch it here, so the
  # notice is shown instead of the bare error.
  fails = !(builtins.tryEval cfg.package.version).success;
  # Reading the priority evaluates each definition, which throws for the alias.
  # The NixOS default is wrapped in mkDefault, so a throw comes from the config.
  prio = builtins.tryEval options.services.postgresql.package.highestPrio;
  isSet = !prio.success || prio.value < (lib.mkDefault null).priority;
  # Without a package of its own, a config fails only through the default,
  # which is PostgreSQL 14 for the state versions 22.05 through 23.05. Older
  # state versions selected versions that failed before 0.2.0.
  defaultIs14 = lib.versionAtLeast stateVersion "22.05" && lib.versionOlder stateVersion "23.11";
in
{
  condition = cfg.enable && fails && (isSet || defaultIs14);
  message = if isSet then ''
    nixos-unstable has removed PostgreSQL 14, and your `services.postgresql.package`
    fails to evaluate. If it selects PostgreSQL 14, upgrade its databases with
    bitcoinix 0.1.6, then set `services.postgresql.package` to the new version
    before you update. Otherwise, evaluate `services.postgresql.package.version`
    of your config to see its error.
  '' else ''
    nixos-unstable has removed PostgreSQL 14, which NixOS selects by default for
    your `system.stateVersion` (${stateVersion}). It holds your PostgreSQL
    databases, such as those of BTCPay Server and NBXplorer. Upgrade them with
    bitcoinix 0.1.6, then set `services.postgresql.package` to the new version
    before you update.
    Don't change `system.stateVersion` to select a newer PostgreSQL: PostgreSQL
    then starts with a new, empty data dir.
  '';
}
