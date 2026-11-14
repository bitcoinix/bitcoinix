{ options, ... }:

{
  condition = options.services.lightning-pool.isDefined;
  message = ''
    Lightning Pool support has been removed. Remove `services.lightning-pool`
    and any Pool-specific onion service or network namespace settings from your
    configuration. Manage Pool separately if needed. Existing data is retained.
  '';
}
