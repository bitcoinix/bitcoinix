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

        # Optional:
        # Import the secure-node preset, an opinionated config to enhance security
        # and privacy.
        #
        # (bitcoinix + "/modules/presets/secure-node.nix")

        {
          # Automatically generate all secrets required by services.
          # The secrets are stored in /etc/nix-bitcoin-secrets
          nix-bitcoin.generateSecrets = true;

          # Enable some services.
          # See ../configuration.nix for all available features.
          services.bitcoind.enable = true;
          services.clightning.enable = true;

          # When using bitcoinix as part of a larger NixOS configuration, set the following to enable
          # interactive access to bitcoinix features (like bitcoin-cli) for your system's main user
          nix-bitcoin.operator = {
            enable = true;
            # FIXME: Set this to your system's main user
            name = "main";
          };

          # The system's main unprivileged user.
          # In an existing NixOS configuration, this setting is usually already defined.
          users.users.main = {
            isNormalUser = true;
            # FIXME: This is unsafe. Use `hashedpassword` or `passwordFile` instead in a real
            # deployment: https://search.nixos.org/options?show=users.users.%3Cname%3E.hashedPassword
            password = "a";
          };

          # Deploying with `nixos-rebuild --target-host root@<node>` logs in as root over SSH.
          # Keep SSH enabled and your key authorized, or the deployment locks you out.
          services.openssh = {
            enable = true;
            settings = {
              PasswordAuthentication = false;
              KbdInteractiveAuthentication = false;
            };
          };
          users.users.root.openssh.authorizedKeys.keys = [
            # FIXME: Add your SSH public key
            "ssh-ed25519 <your_pubkey>"
          ];

          # If you use a custom nixpkgs version for evaluating your system
          # (instead of `bitcoinix.inputs.nixpkgs` like in this example),
          # consider setting `useVersionLockedPkgs = true` to use the exact pkgs
          # versions for bitcoinix services that are tested by bitcoinix.
          # The downsides are increased evaluation times and increased system
          # closure size.
          #
          # nix-bitcoin.useVersionLockedPkgs = true;

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
