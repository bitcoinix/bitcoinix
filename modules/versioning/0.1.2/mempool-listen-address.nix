{ config, ... }:

{
  condition = config.services.mempool.enable;
  message = ''
    The mempool backend now listens on `services.mempool.address` (default 127.0.0.1)
    instead of on all interfaces. The nginx frontend is unaffected. To reach the
    backend API from other hosts directly, set `services.mempool.address`.
    The MariaDB server that mempool enables now listens on 127.0.0.1 by default
    (`services.mysql.settings.mysqld.bind-address`). To keep accessing MariaDB
    over the network, set this option to the desired listen address.
  '';
}
