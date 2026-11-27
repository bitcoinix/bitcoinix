{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services;
  nbLib = config.bitcoinix.lib;
  operatorName = config.bitcoinix.operator.name;
in {
  imports = [
    ../modules.nix
    ./enable-tor.nix
  ];

  options = {
    # Used by ../versioning/0.0.65/secure-node-secrets-dir.nix
    # and ../versioning/0.2.0/secure-node-ssh-password-login.nix
    bitcoinix.secure-node-preset-enabled = {};
  };

  config =  {
    networking.firewall.enable = true;

    bitcoinix.security.dbusHideProcessInformation = true;

    # Use doas instead of sudo
    security.doas.enable = true;
    security.sudo.enable = false;
    environment.shellAliases.sudo = "doas";

    environment.systemPackages = with pkgs; [
      jq
    ];

    # Add a SSH onion service
    services.tor.relay.onionServices.sshd = nbLib.mkOnionService { port = 22; };
    bitcoinix.onionAddresses.access.${operatorName} = [ "sshd" ];
    # The onion service lets anyone try SSH logins over Tor, and the operator
    # is in the groups that control funds. So accept only keys by default.
    services.openssh.settings = {
      PasswordAuthentication = mkDefault false;
      KbdInteractiveAuthentication = mkDefault false;
    };

    services.bitcoind = {
      enable = true;
      listen = true;
      dbCache = 1000;
    };

    bitcoinix.nodeinfo.enable = true;

    services.backups.frequency = "daily";

    # operator
    bitcoinix.operator.enable = true;
    users.users.${operatorName} = {
      openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
    };
  };
}
