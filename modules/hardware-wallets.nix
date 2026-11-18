{ config, lib, pkgs, ... }:

with lib;
let
  options.services.hardware-wallets = {
    ledger = mkOption {
      type = types.bool;
      default = false;
      description = ''
        If enabled, the ledger udev rules will be installed.
      '';
    };
    trezor = mkOption {
      type = types.bool;
      default = false;
      description = ''
        If enabled, the trezor udev rules will be installed.
      '';
    };
    trezorBridge = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run the Trezor Bridge (trezord) for apps that reach the Trezor through it.
        Requires {option}`services.hardware-wallets.trezor`. HWI and trezorctl open
        the device directly and don't need the bridge.

        The bridge serves an HTTP API without authentication on 127.0.0.1:21325.
        Every local user and service can then use the Trezor through it, not only
        members of {option}`services.hardware-wallets.group`. For example, they can
        read its public keys while it's unlocked.
      '';
    };
    group = mkOption {
      type = types.str;
      default = "hardware-wallets";
      description = ''
        Group the hardware wallet udev rules apply to.
      '';
    };
  };

  cfg = config.services.hardware-wallets;

  # Our rules run after systemd's 70-uaccess.rules, which gives hardware wallets to
  # the active local session, and remove that tag before 73-seat-late.rules applies
  # it. They also run after the nixpkgs Trezor rules, so our group wins.
  rulesFile = name: "/etc/udev/rules.d/71-hardware-wallets-${name}.rules";

  # Whether trezord gets the group from its user, its unit or the group's members
  trezordHasGroup = let
    user = config.users.users.trezord or {};
    unit = config.systemd.services.trezord.serviceConfig or {};
    # `SupplementaryGroups` can be a list, or a string of space-separated groups
    unitGroups = filter (group: group != "")
      (concatMap (splitString " ") (toList (unit.SupplementaryGroups or [])));
    groups = [ (user.group or null) (unit.Group or null) ] ++ user.extraGroups or [] ++ unitGroups;
  in elem cfg.group groups || elem "trezord" config.users.groups.${cfg.group}.members;
in {
  inherit options;

  config = mkMerge [
    (mkIf (cfg.ledger || cfg.trezor) {
      assertions = [
        { assertion = (config.services.bitcoind.disablewallet == null || !config.services.bitcoind.disablewallet);
          message = ''
            Hardware-Wallets are not compatible with bitcoind.disablewallet.
          '';
        }
      ];

      environment.systemPackages = [
        config.nix-bitcoin.pkgs.hwi
        # Provides lsusb for debugging
        pkgs.usbutils
      ];

      users.groups.${cfg.group} = {};
      nix-bitcoin.operator.groups = [ cfg.group ];
    })

    (mkIf cfg.ledger {
      # Every Ledger device that systemd's hardware wallet hwdb lists: all products of
      # vendor 2c97, since Ledger models and firmware versions use many product IDs,
      # and the HW.1 and early Nano IDs of vendor 2581.
      # Don't use rules from nixpkgs because we want to use our own group.
      services.udev.packages = lib.singleton (pkgs.writeTextFile {
        name = "ledger-udev-rules";
        destination = rulesFile "ledger";
        text = ''
          SUBSYSTEMS=="usb", ATTRS{idVendor}=="2c97", MODE="0660", GROUP="${cfg.group}", TAG-="uaccess"
          SUBSYSTEMS=="usb", ATTRS{idVendor}=="2581", ATTRS{idProduct}=="1b7c|2b7c|3b7c|4b7c", MODE="0660", GROUP="${cfg.group}", TAG-="uaccess"
        '';
      });
    })
    (mkIf cfg.trezor {
      environment.systemPackages = [ config.nix-bitcoin.pkgs.nbPython3Packages.trezor ];
      # Don't use rules from nixpkgs because we want to use our own group.
      services.udev.packages = lib.singleton (pkgs.writeTextFile {
        name = "trezord-udev-rules";
        destination = rulesFile "trezor";
        text = ''
          # TREZOR v1 (One)
          SUBSYSTEM=="usb", ATTR{idVendor}=="534c", ATTR{idProduct}=="0001", MODE="0660", GROUP="${cfg.group}", TAG-="uaccess", SYMLINK+="trezor%n"
          KERNEL=="hidraw*", ATTRS{idVendor}=="534c", ATTRS{idProduct}=="0001", MODE="0660", GROUP="${cfg.group}", TAG-="uaccess"

          # TREZOR v2 (T)
          SUBSYSTEM=="usb", ATTR{idVendor}=="1209", ATTR{idProduct}=="53c0", MODE="0660", GROUP="${cfg.group}", TAG-="uaccess", SYMLINK+="trezor%n"
          SUBSYSTEM=="usb", ATTR{idVendor}=="1209", ATTR{idProduct}=="53c1", MODE="0660", GROUP="${cfg.group}", TAG-="uaccess", SYMLINK+="trezor%n"
          KERNEL=="hidraw*", ATTRS{idVendor}=="1209", ATTRS{idProduct}=="53c1", MODE="0660", GROUP="${cfg.group}", TAG-="uaccess"
        '';
      });
      warnings = optional (config.services.trezord.enable && !trezordHasGroup) ''
        services.trezord.enable is set, but trezord can't open the Trezor, since the
        udev rules of services.hardware-wallets.trezor give it only to group
        `${cfg.group}`. To run the bridge, set
        services.hardware-wallets.trezorBridge = true. Every local user and service
        can then use the Trezor through the bridge's unauthenticated API on
        127.0.0.1:21325.
      '';
    })
    (mkIf (cfg.trezor && cfg.trezorBridge) {
      services.trezord.enable = true;
      # On the unit, not the user, so that a switch restarts a running bridge with it
      systemd.services.trezord.serviceConfig.SupplementaryGroups = [ cfg.group ];
    })
  ];
}
