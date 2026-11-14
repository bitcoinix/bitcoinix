{ config, ... }:

{
  condition = config.services.nbxplorer.enable;
  message = ''
    The nbxplorer database backend has changed from DBTrie to Postgresql.
    The new `services.postgresql` database name is `nbxplorer`.
    The migration happens automatically after deploying.
    Migration time for a large server with a 5GB DBTrie database takes about 40 minutes.
    See also: https://github.com/btcpayserver/NBXplorer/blob/b691999b14eb2a06547ffa708c11574fa323d769/docs/Postgres-Migration.md
  '';
}
