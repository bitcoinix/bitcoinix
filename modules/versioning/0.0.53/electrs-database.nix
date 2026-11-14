{ config, lib, ... }:

with lib;
{
  condition = config.services.electrs.enable;
  message = let
    dbPath = "${config.services.electrs.dataDir}/mainnet";
  in ''
    Electrs 0.9.0 has switched to a new, more space efficient database format,
    reducing storage demands by ~60% [1].
    When started, electrs will automatically reindex the bitcoin blockchain.
    This can take a few hours, depending on your hardware. The electrs server is
    inactive during reindexing.

    To upgrade, do the following:

    - If you have less than 40 GB of free space [2] on the electrs data dir volume:
      1. Delete the database:
         systemctl stop electrs && rm -r ${escapeShellArg dbPath}
      2. Deploy the new system config to your node

    - Otherwise:
      1. Deploy the new system config to your node
      2. Check that electrs works as expected and delete the old database:
         rm -r ${escapeShellArg dbPath}

    [1] https://github.com/romanz/electrs/blob/557911e3baf9a000f883a6f619f0518945a7678d/doc/usage.md#upgrading
    [2] This is based on the bitcoin blockchain size as of 2021-09.
        The general formula is, approximately, size_of(${dbPath}) * 0.6
        This includes the final database size (0.4) plus some extra storage (0.2).
  '';
}
