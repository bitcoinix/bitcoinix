{ config, ... }:

{
  condition = config.services.orchard.enable or false;
  message = ''
    Orchard now enforces its AI enable switch on the server. Previously,
    configured scheduled and Telegram agents could keep sending mint data
    to the AI provider even with AI turned off in Orchard's settings.
    Review the AI setting: leave it off to prevent new inference requests,
    or enable it if you intend to run these agents. Existing agent schedules
    are retained and resume when AI is enabled again.
  '';
}
