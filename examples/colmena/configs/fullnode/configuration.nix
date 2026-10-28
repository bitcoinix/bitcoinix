{
  config,
  ...
}:
{
  imports = [
    # FIXME: This file depends entirely on your hardware and environment;
    # replace it with your node's.
    ./hardware-configuration.nix
  ];

  networking = {
    hostName = "fullnode";

    # FIXME: Set your node's network interface (see `ip link`)
    firewall.interfaces.enp1s0 = {
      allowedTCPPorts = [
        # nginx reverse proxy
        80
      ];
    };
  };

  ## Services
  services = {
    # Reverse proxy that serves mempool on the local network over plain HTTP.
    # It forwards to the mempool frontend, which listens on localhost only.
    # Before exposing mempool to the internet, add TLS (`enableACME`,
    # `forceSSL` and `security.acme`) and rate limiting; see the description of
    # `services.mempool.frontend.enable`.
    nginx = {
      enable = true;
      recommendedProxySettings = true;

      # FIXME: Set your domain. It is also the certificate's domain if you
      # enable ACME. (`mempool` is taken: the frontend's own virtual host.)
      virtualHosts."mempool.example.com" = {
        default = true;
        locations."/" = {
          proxyPass = "http://${config.services.mempool.frontend.address}:${toString config.services.mempool.frontend.port}/";
          proxyWebsockets = true;
        };
      };
    };

    # This node keeps the bitcoind and fulcrum data on an extra disk (e.g.
    # 2 TB), mounted at /mnt/data in hardware-configuration.nix. Drop the
    # `dataDir` lines to use the defaults under /var/lib.

    ### BITCOIND
    bitcoind = {
      enable = true;
      dataDir = "/mnt/data/bitcoind";
    };

    ### CLIGHTNING
    clightning = {
      enable = true;
      replication = {
        enable = true;
        encrypt = true;
        local.directory = "/var/backup/clightning";
      };

      plugins = {
        # CLN REST server
        clnrest.enable = true;
      };
    };

    ### RIDE THE LIGHTNING
    rtl = {
      enable = true;
      # Set this to add a clightning node interface.
      # Automatically enables clightning.
      nodes.clightning.enable = true;
    };

    ### MEMPOOL
    mempool = {
      enable = true;
      electrumServer = "fulcrum";
    };

    ### FULCRUM
    fulcrum = {
      enable = true;
      dataDir = "/mnt/data/fulcrum";
    };

    ### Backups
    backups.enable = true;
  };

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "26.05";
}
