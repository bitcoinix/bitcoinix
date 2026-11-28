#### Orchard Tor routing and AI controls

Orchard now uses Tor for preflight DNS lookups and all public TCP port checks
when its Tor proxy is enabled, without falling back to local DNS or direct
connections. Private destinations remain blocked. Alternative loopback mint
addresses and IPv6 Tor SOCKS listeners are also supported.

The server now enforces the AI enable switch for inference, scheduled agents,
Telegram conversations and agent tools. See the
[upgrade note](../../upgrading/0.2.1/orchard-ai-switch.md) for how this affects
existing agents, and the [Orchard guide](../../services/orchard.md#outgoing-requests-and-ai)
for the data these features share with the provider.
