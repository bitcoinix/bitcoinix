# This is a system configuration template that uses bitcoinix.
#
# You can adapt this to an existing system flake by copying the parts
# relevant to bitcoinix.
#
# Make sure to check and edit all lines marked by 'FIXME:'

{
  description = "A basic bitcoinix node";

  inputs = {
    # Pin the latest release tag listed at https://github.com/bitcoinix/bitcoinix/tags
    bitcoinix.url = "github:bitcoinix/bitcoinix/v0.1.2";

    nixpkgs.follows = "bitcoinix/nixpkgs";
    nixpkgs-unstable.follows = "bitcoinix/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, bitcoinix, ... }: {

    nixosConfigurations.fullnode = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        bitcoinix.nixosModules.default

        # The secure-node preset, an opinionated config to enhance security and
        # privacy: firewall, Tor for the services' outgoing connections, doas
        # instead of sudo, an `operator` user and an SSH onion service.
        (bitcoinix + "/modules/presets/secure-node.nix")

        {
          nix-bitcoin = {
            # Automatically generate all secrets required by services.
            # The secrets are stored in /etc/nix-bitcoin-secrets. Back them up
            # yourself: they are not part of this flake.
            generateSecrets = true;

            # The bitcoinix release that your config is written for. After you
            # update the pinned release, evaluation fails if your config needs
            # changes and says what to do; then set this to the new release.
            configVersion = "0.1.2";

            # The preset adds the user `operator` for interactive access to bitcoinix
            # features (like bitcoin-cli). It has no password and logs in with root's
            # SSH keys. In a larger NixOS configuration, make your main user the
            # operator instead:
            # operator.name = "<your main user>";

            # If you use a custom nixpkgs version for evaluating your system
            # (instead of `bitcoinix.inputs.nixpkgs` like in this example),
            # consider setting `useVersionLockedPkgs = true` to use the exact pkgs
            # versions for bitcoinix services that are tested by bitcoinix.
            # The downsides are increased evaluation times and increased system
            # closure size.
            #
            # useVersionLockedPkgs = true;
          };

          services = {
            # Enable some services.
            # See ../configuration.nix for all available features.
            bitcoind.enable = true;
            clightning.enable = true;

            # Deploying with `nixos-rebuild --target-host root@<node>` logs in as root over SSH.
            # Keep SSH enabled and your key authorized, or the deployment locks you out.
            openssh = {
              enable = true;
              settings = {
                PasswordAuthentication = false;
                KbdInteractiveAuthentication = false;
              };
            };
          };
          users.users.root.openssh.authorizedKeys.keys = [
            # FIXME: Add your SSH public key
            "ssh-ed25519 <your_pubkey>"
          ];

          # FIXME: Placeholders. This part depends entirely on your node's hardware
          # (boot loader, disks): replace it by importing the hardware-configuration.nix
          # that `nixos-generate-config` writes on the node.
          boot.loader.grub.device = "/dev/sda";
          fileSystems."/" = {
            device = "/dev/disk/by-label/nixos";
            fsType = "ext4";
          };

          # The NixOS release that your node was installed with.
          # Read the comment on this option before changing it:
          # https://search.nixos.org/options?show=system.stateVersion
          system.stateVersion = "26.05";
        }
      ];
    };
  };
}
