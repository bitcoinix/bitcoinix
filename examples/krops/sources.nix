{ extraSources, krops }:

krops.lib.evalSource [({
  nixos-config.file = builtins.toFile "nixos-config" ''
    {
      imports = [
        ./configuration.nix
        <nix-bitcoin/modules/deployment/krops.nix>
      ];
    }
  '';

  "configuration.nix".file = toString ../configuration.nix;

  # Enable `useChecksum` for sources which might be located in the nix store
  # and which therefore might have static timestamps.

  nixpkgs.file = {
    path = toString <nixpkgs>;
    useChecksum = true;
    # TODO-EXTERNAL:
    # Work around symlink sync error on macOS/BSD
    # (https://github.com/NixOS/nixpkgs/issues/180046)
    # by excluding the symlinks that are present in nixpkgs.
    # NixOS evaluation doesn't use them.
    filters = map (pattern: { type = "exclude"; inherit pattern; }) [
      "/.version"
      "/maintainers/scripts/check-by-name.sh"
      "/pkgs/development/libraries/readline/update-patch-set.sh"
    ];
  };

  nix-bitcoin.file = {
    path = toString <nix-bitcoin>;
    useChecksum = true;
    filters = map (pattern: { type = "exclude"; inherit pattern; }) [
      ".git"
      # TODO-EXTERNAL:
      # Exclude the symlinks of bitcoinix, like those of nixpkgs above.
      # Deploying doesn't use them.
      "/docs/img/logo-text.svg"
      "/theme/favicon.png"
      "/theme/favicon.svg"
    ];
  };

  secrets.file = toString ../secrets;
} // extraSources)]
