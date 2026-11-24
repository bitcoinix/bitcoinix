{ config, lib, ... }:

let
  inherit (config.services) clightning;
  inherit (clightning) replication;
  dirs = lib.optional (replication.local.directory != null && replication.local.setupDirectory)
      "`services.clightning.replication.local.directory`"
    ++ lib.optional (replication.sshfs.destination != null || replication.encrypt)
      "`/var/cache/clightning-replication`";
in
{
  condition = clightning.enable && replication.enable && dirs != [];
  message = ''
    Group `${clightning.group}` can no longer write the Core Lightning replication
    dirs ${lib.concatStringsSep " and " dirs}. Only clightning writes there.
    Group members, like the operator user, can still read these dirs. A script
    that creates, renames or deletes entries there as a group member now fails.
    Run it as user `${clightning.user}` or as root instead.
  '';
}
