# This flake just mirrors input `nixos-search`.
# Because `nixos-search` is a dev-only dependency, we don't add
# it to the main flake.
{
  inputs.nixos-search.url = "github:nixos/nixos-search";

  outputs = { self, nixos-search }: let
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    inherit (nixos-search.inputs.nixpkgs) lib;
  in {
    packages = lib.genAttrs systems (system: {
      # Patch `flake-info` to run in an offline environment (./flake-info-sandboxed.sh).
      # It routes `nixpkgs` through NIX_PATH via <nixpkgs> and mocks `flake-schemas`
      # to prevent network-dependent fetches from GitHub.
      flake-info = nixos-search.packages.${system}.flake-info.overrideAttrs (old: {
        patches = (old.patches or []) ++ [
          ./offline-fixes.patch
        ];
      });
    });

    # Used by ./ci-test.sh
    inherit (nixos-search.inputs.nixpkgs) legacyPackages;
  };
}
