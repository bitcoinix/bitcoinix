#### Orchard Cashu mint dashboard

Add `cashu-orchard` 1.12.1 and the optional `services.orchard` service for
the local CDK mint. It provides mint analytics and management with a separate
service account, read-only database access and mutually authenticated TLS for
CDK's management RPC. Localhost access, onion services and network namespace
isolation are supported. The Tor preset also proxies external dashboard, AI and
Telegram requests. With the proxy enabled, public URL and TCP port checks resolve
hostnames through Tor and reject private destinations without falling back to
local DNS or direct connections. Public icon fetches stay on the proxy even for local-looking names.
Alternative loopback mint addresses and IPv6 Tor SOCKS listeners are supported.

AI is off by default. The server enforces this switch for inference, scheduled
agents, Telegram conversations and agent tools. Turning AI off blocks new work;
provider requests already in flight may finish. Active schedules resume when AI
is enabled again. See the [Orchard guide](../../services/orchard.md) for setup,
AI data sharing and recovery.
