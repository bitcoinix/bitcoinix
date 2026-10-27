{
  config,
  lib,
  pkgs,
  ...
}:
{
  nix = {
    settings = {
      auto-optimise-store = true;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };

    # Perform garbage collection weekly to maintain low disk usage
    gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "weekly";
      options = lib.mkDefault "--delete-older-than 7d";
    };

    # Free up to 1GiB whenever there is less than 100MiB left.
    extraOptions = ''
      min-free = ${toString (100 * 1024 * 1024)}
      max-free = ${toString (1024 * 1024 * 1024)}
    '';

    optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };
  };

  # Set maximum number of NixOS generations
  boot.loader.grub.configurationLimit = lib.mkDefault 5;

  time.timeZone = "Europe/Berlin";

  programs = {
    bash.interactiveShellInit = "set -o vi";
    vim = {
      enable = true;
      defaultEditor = lib.mkDefault true;
    };
    screen.enable = true;

    # Optional monitoring tools
    htop.enable = true;
    iotop.enable = true;
    iftop.enable = true;
  };

  environment.systemPackages = with pkgs; [
    # Other monitoring tools
    ncdu
    btop
  ];

  users = {
    mutableUsers = false;
    motd = ''
      ===============================================
      This system is managed by NixOS/Colmena.

      Do not make manual changes.
      ===============================================
    '';
    users = {
      root = {
        openssh.authorizedKeys.keys = [
          # SSH access / backup keys
          "ssh-ed25519 <your_pubkey> backup_key"
          "ssh-ed25519 <your_pubkey> access_key"
        ];

        hashedPasswordFile = config.age.secrets.root_password.path;
      };
    };
  };

  services = {
    openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
    };

    journald.extraConfig = ''
      Storage=persistent
      SystemMaxUse=500M
      MaxRetentionSec=1month
    '';
  };
}
