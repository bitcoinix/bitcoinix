{ config, ... }:

{
  condition = config.services.mempool.enable;
  message = ''
    mempool 3.3 migrates its database to a new schema on first start. The migration
    can't be undone, and rolling back the NixOS generation keeps the migrated
    database, which mempool 3.2 can't use. To keep a way back, dump the database
    (`${config.services.mempool.database.name}`) before deploying.
  '';
}
