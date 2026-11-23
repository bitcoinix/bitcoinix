#### PostgreSQL 14 removed

nixos-unstable has removed PostgreSQL 14. Nodes that still use PostgreSQL 14, such as
for BTCPay Server, fail evaluation. By default, this applies to a `system.stateVersion`
from 22.05 through 23.05. Upgrade the databases before you update bitcoinix, see the
[upgrade notes](../../upgrading/0.2.0/postgresql-14-removed.md).
