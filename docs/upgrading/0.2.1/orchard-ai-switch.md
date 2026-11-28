#### Orchard AI enable switch

Orchard now checks its AI enable switch on the server. Previously, configured
scheduled agents and the Telegram conversation agent could send mint data to the
provider even when AI was turned off in the web settings.

Review the AI setting in Orchard. Leave it off to block new inference requests,
scheduled runs, Telegram AI conversations and further agent tool calls. Enable it
only if you intend to use these features and share their inputs with the configured
provider. Agent configurations and schedules are retained; active schedules resume
when AI is enabled again. Provider requests already in flight may finish, and data
already sent cannot be recalled. No database migration or credential reset is needed.

See [Outgoing requests and AI](../../services/orchard.md#outgoing-requests-and-ai)
for the affected features and Tor behavior.
