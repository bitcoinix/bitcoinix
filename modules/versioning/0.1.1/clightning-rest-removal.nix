{ options, ... }:

let
  clightningRestUsed = options.services.clightning-rest.isDefined
    || options.services.rtl.cl-rest.isDefined;
in
{
  condition = clightningRestUsed;
  message = ''
    c-lightning-REST is no longer maintained and has been removed.
    Remove `services.clightning-rest`, the legacy `services.rtl.cl-rest` option,
    and any associated onion service or network namespace settings from your
    configuration. Use `services.clightning.plugins.clnrest` instead.
    Replace `lndconnect-clightning` and `lndconnect-clightning-wg` with
    `lnconnect-clnrest` and `lnconnect-clnrest-wg` and reconnect your clients.
    Custom clients must adapt to clnrest's API. clnrest shares Core Lightning's
    service sandbox, network namespace and Tor-enforcement settings.

    Existing data is retained, but the backups service no longer includes the
    former data directory (default: /var/lib/clightning-rest).
  '';
}
