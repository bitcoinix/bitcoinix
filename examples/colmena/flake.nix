{
  description = "Colemna Hive configuration (fullnode)";

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

          specialArgs = {
            system = "x86_64-linux";
          };

          nodeNixpkgs = {
            fullnode = import inputs.nixpkgs {
              system = "x86_64-linux";
            };
          };

          nodeSpecialArgs = { };
        };

        defaults = {
          imports = [
            # Include the common defaults to all machine configuration
            ./nixos/common.nix
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
              targetHost = "${name}.example.com";
              targetUser = "root";
              buildOnTarget = true;
            };

            imports = [
              inputs.bitcoinix.nixosModules.default
              (inputs.bitcoinix + "/modules/presets/secure-node.nix")

              # Load node configuration
              ./nixos/configs/${name}/configuration.nix
            ];

            nix-bitcoin = {
              # Automatically generate all secrets required by services.
              # The secrets are stored in /etc/nix-bitcoin-secrets on remote
              # node and must be backuped.
              generateSecrets = true;
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
