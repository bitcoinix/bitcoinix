{ config, ... }:

{
  condition = config.services.rtl.enable;
  message = ''
    RTL is now bound to the units of its enabled backends (lnd,
    clightning). It stops when one of them stops, crashes or exits, and a
    backend's start starts it again once all of its backends run. With
    both backends enabled, stopping one of them also stops RTL for the
    other one, and starting RTL starts a stopped backend too. Deploying
    this change restarts each backend that RTL uses once.
  '';
}
