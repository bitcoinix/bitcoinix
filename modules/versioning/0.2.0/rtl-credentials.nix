{ config, lib, ... }:

with lib;
let
  cfg = config.services.rtl;
in
{
  condition = cfg.enable;
  message = ''
    RTL now gets its own lnd macaroon and clightning rune instead of the admin
    credentials. Its start writes them to the paths of its old copies in
    ${cfg.dataDir}, `macaroons/admin.macaroon` and `clightning-admin-rune`, and
    removes the copy of a backend that RTL doesn't use. An app that reads these
    files gets authorization errors after the deploy for the calls that RTL
    doesn't make. Give it its own credentials, for example a custom macaroon
    with `services.lnd.macaroons.<name>`.
  '' + optionalString cfg.nodes.lnd.enable ''
    lnd restarts once during the deploy to create RTL's macaroon.
  '';
}
