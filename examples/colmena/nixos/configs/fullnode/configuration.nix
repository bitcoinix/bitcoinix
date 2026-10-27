{
  config,
  ...
}:
{
  imports = [
    ./hardware-configuration.nix

    # Common modules (common.nix included by all hosts in the `flake.nix`)
    ../vm.nix
  ];

  networking = {
    useDHCP = false;
    interfaces.enp1s0.useDHCP = true;

    hostName = "fullnode";

    firewall.interfaces.enp1s0 = {
      allowedTCPPorts = [
        # nginx reverse proxy
        80
        443
      ];
    };
  };

  ## Services
  services = {
    # Reverse proxy to services
    nginx = {
      enable = true;
      recommendedProxySettings = true;

      virtualHosts = {
        "mempool.example.com" = {
          enableACME = true;
          forceSSL = true;
          locations."/" = {
            proxyPass = "http://127.0.0.1:${toString config.services.mempool.frontend.port}/";
            proxyWebsockets = true;
          };
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
    clightning-rest.enable = true;

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
    configVersion = "0.0.139";
  };

  # This value determines the NixOS release with which your system is to be
  # compatible, in order to avoid breaking some software such as database
  # servers. You should change this only after NixOS release notes say you
  # should.
  system.stateVersion = "26.05";
}
