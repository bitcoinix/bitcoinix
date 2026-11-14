{ options, ... }:

{
  condition = options.services.lightning-loop.isDefined
    || options.services.rtl.nodes.lnd.loop.isDefined;
  message = ''
    Lightning Loop support and RTL's Loop integration have been removed.

    Before switching, make sure no Loop swap is in progress (`loop listswaps`);
    a Loop Out whose preimage was already revealed can lose the swap amount
    once `loopd` stops.

    Remove `services.lightning-loop`, `services.rtl.nodes.lnd.loop` and any
    Loop-specific onion service or network namespace settings from your
    configuration. Manage Loop separately if needed. Existing data is retained.
  '';
}
