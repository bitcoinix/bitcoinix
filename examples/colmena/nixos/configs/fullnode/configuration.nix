{
  config,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix

    # Common modules (common.nix included by all hosts in the `flake.nix`)
    ../../vm.nix
  ];

  networking = {
    useDHCP = false;
    interfaces.enp1s0.useDHCP = true;

    hostName = "fullnode";

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

      # Ref.:
      # - https://github.com/ElementsProject/lightning/blob/master/doc/lightningd-config.5.md
      extraConfig = ''
        alias=bitcoinix[cln]
      '';

      #### Plugins
      plugins = { };
    };

    # == CLN REST server
    clightning.plugins.clnrest.enable = true;

    ### RIDE THE LIGHTNING
    rtl.enable = true;

    # Set this to add a clightning node interface.
    # Automatically enables clightning.
    rtl.nodes.clightning.enable = true;

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

  ## Nix-Bitcoin's specific options
  nix-bitcoin = {
    # The nix-bitcoin release version that your config is compatible with. When
    # upgrading to a backwards-incompatible release, nix-bitcoin will display an
    # an error and provide hints for migrating your config to the new release.
    configVersion = "0.1.3";
  };

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "26.05";
}
