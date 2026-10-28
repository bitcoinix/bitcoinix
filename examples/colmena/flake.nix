{
  description = "Colmena hive with a bitcoinix node (fullnode)";

  inputs = {
    # Pin the latest release tag listed at https://github.com/bitcoinix/bitcoinix/tags
    bitcoinix.url = "github:bitcoinix/bitcoinix/v0.1.2";

    # Use the nixpkgs that bitcoinix is tested with
    nixpkgs.follows = "bitcoinix/nixpkgs";

    colmena = {
      url = "github:nix-community/colmena/v0.5.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.stable.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      ...
    }@inputs:
    let
      toolingSupportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = inputs.nixpkgs.lib.genAttrs toolingSupportedSystems;
    in
    {
      colmenaHive = inputs.colmena.lib.makeHive {
        meta = {
          # Do not allow deployments without a node filter set
          allowApplyAll = false;

          # Default nixpkgs. This must be specified, otherwise the colmena will not build:
          # "Hint: Use the same version of Colmena as in the Flake input."
          # " ... "
          # "error: meta.nixpkgs must be specified in hermetic mode."
          nixpkgs = import inputs.nixpkgs {
            system = "x86_64-linux";
          };
        };

        # Optional: modules that every node imports. common.nix also gives
        # root the SSH access that Colmena deploys with; keep that if you
        # drop it.
        defaults = {
          imports = [
            ./common.nix
          ];
        };

        ##################
        #### FULL NODE
        ##################
        fullnode =
          let
            name = "fullnode";
          in
          { ... }:
          {
            deployment = {
              # FIXME: The address that Colmena reaches the node at over SSH
              targetHost = "${name}.example.com";
              # Colmena logs in as root with your SSH key
              targetUser = "root";
              # Build on the node, for its own architecture: no cross-building,
              # and you can deploy from macOS
              buildOnTarget = true;
            };

            imports = [
              inputs.bitcoinix.nixosModules.default

              # Secure defaults: firewall, Tor for the services' outgoing
              # connections, doas instead of sudo, an `operator` user with
              # root's SSH keys and an SSH onion service
              (inputs.bitcoinix + "/modules/presets/secure-node.nix")

              # Load node configuration
              ./configs/${name}/configuration.nix
            ];

            nix-bitcoin = {
              # Generate the secrets that the services need on the node, in
              # /etc/nix-bitcoin-secrets. Back them up yourself: they are not
              # part of this flake.
              generateSecrets = true;

              # The bitcoinix release that your config is written for. After you
              # update the pinned release, evaluation fails if your config needs
              # changes and says what to do; then set this to the new release.
              configVersion = "0.1.2";
            };
          };
      };

      # `nix develop` provides the colmena version that matches the hive
      devShells = forAllSystems (system: {
        default = inputs.nixpkgs.legacyPackages.${system}.mkShell {
          packages = [ inputs.colmena.packages.${system}.colmena ];
        };
      });
    };
}
