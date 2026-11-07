{
  description = ''
    A collection of Nix packages and NixOS modules for easily
    installing full-featured Bitcoin nodes with an emphasis on security.
  '';

  inputs = {
    # TODO-EXTERNAL: Switch to nixos-unstable once it includes Core Lightning
    # 26.06.10. As of 2026-11-07 it still carries 26.06.9; retain the security fix.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    extra-container = {
      url = "github:extra-container/extra-container/v1.0.1";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        # Only these 64-bit Linux platforms are supported and tested.
      ];

      test = import ./test/tests.nix nixpkgs.lib self.nixosModules.default;
    in {
      lib = {
        mkNbPkgs = {
          system
          , pkgs ? nixpkgs.legacyPackages.${system}
        }:
          import ./pkgs { inherit pkgs; };

        test = {
          inherit (test) scenarios;
        };

        inherit supportedSystems;
      };

      overlays.default = final: prev: let
        nbPkgs = self.lib.mkNbPkgs { inherit (final) system; pkgs = final; };
      in removeAttrs nbPkgs [ "pinned" "krops" ];

      nixosModules.default = { config, pkgs, lib, ... }: {
        imports = [ ./modules/modules.nix ];

        options = with lib; {
          nix-bitcoin.useVersionLockedPkgs = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Use the nixpkgs version locked by this flake for `nix-bitcoin.pkgs`.
              Only relevant if you are using a nixpkgs version for evaluating your system
              that differs from the one that is locked by this flake (via input `nixpkgs`).
              If this is the case, enabling this option uses the tested package set
              for bitcoinix services.
              The downsides are increased evaluation times and increased system
              closure size. The system's nixpkgs.overlays and nixpkgs.config do
              not apply to these pinned packages. System evaluation requires
              unstable nixpkgs regardless of this option.

              If `false`, the default system pkgs are used. Use an unstable nixpkgs
              for your system; release branches are not supported.
            '';
          };
        };

        config = {
          nix-bitcoin.revision = lib.mkDefault (self.rev or self.dirtyRev or null);

          nix-bitcoin.pkgs =
            if config.nix-bitcoin.useVersionLockedPkgs
            then (self.lib.mkNbPkgs { inherit (pkgs.stdenv.hostPlatform) system; }).modulesPkgs
            else (self.lib.mkNbPkgs { inherit (pkgs.stdenv.hostPlatform) system; inherit pkgs; }).modulesPkgs;
        };
      };

      templates.default = {
        description = "Basic node template";
        path = ./examples/flakes;
      };

    } // (flake-utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        nbPkgs = self.lib.mkNbPkgs { inherit system pkgs; };
      in rec {
        checks = {
          ci-workflows = pkgs.runCommand "nix-bitcoin-ci-workflows" {
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
          } ''
            python ${./test/ci/workflow-tests.py} ${./.github/workflows/test.yml} ${./test/ci}
            touch "$out"
          '';

          module-config = import ./test/configuration.nix {
            inherit pkgs;
            nixBitcoinModule = self.nixosModules.default;
          };
          test-runner = pkgs.runCommand "nix-bitcoin-test-runner" {
            nativeBuildInputs = [ pkgs.python3 ];
          } ''
            python ${./test/runner-tests.py} ${pkgs.writeText "test-suite.py" (import ./test/lib/test-script.nix)}
            touch "$out"
          '';
          cve-tools = pkgs.runCommand "nix-bitcoin-cve-tools" {
            nativeBuildInputs = [ pkgs.python3 ];
          } ''
            python ${./test/ci/cve-tests.py} ${./test/ci}
            touch "$out"
          '';
        };

        packages = flake-utils.lib.flattenTree (removeAttrs nbPkgs [
          "fetchNodeModules"
          "krops"
          "modulesPkgs"
          "pinned"
          "nbPython3Packages"
        ]) // {
          inherit (import ./examples/qemu-vm/minimal-vm.nix self pkgs system)
            # A simple demo VM.
            # See ./examples/flakes/flake.nix on how to use bitcoinix with flakes.
            runVM
            vm;
        };

        # Allow accessing the whole nested `nbPkgs` attrset (including `modulesPkgs`)
        # via this flake.
        # `packages` is not allowed to contain nested pkgs attrsets.
        legacyPackages =
          nbPkgs //
          (test.pkgs self pkgs) //
          {
            extra-container = self.inputs.extra-container.packages.${system}.default;

            ciTestInfo = import ./test/ci/test-info.nix pkgs legacyPackages.instantiateTests;
          };

        apps = rec {
          default = vm;

          # Run a basic bitcoinix node in a VM
          vm = {
            type = "app";
            program = toString packages.runVM;
          };
        };

        devShells.default = import ./dev/dev-env/dev-shell.nix pkgs;
      }
    ));
}
