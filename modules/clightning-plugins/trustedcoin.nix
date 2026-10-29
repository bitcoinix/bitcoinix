{ config, lib, pkgs, ... }:

with lib;
let cfg = config.services.clightning.plugins.trustedcoin; in
{
  options.services.clightning.plugins.trustedcoin = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to enable Trustedcoin (Core Lightning plugin).
        Warning: With {option}`tor.proxy` disabled, trustedcoin fetches block data
        over clearnet, so option {option}`services.clightning.tor.enforce` is
        automatically disabled for the whole clightning service.
      '';
    };

    package = mkOption {
      type = types.package;
      default = config.nix-bitcoin.pkgs.trustedcoin;
      defaultText = "config.nix-bitcoin.pkgs.trustedcoin";
      description = "The package providing trustedcoin binaries.";
    };

    tor.proxy = mkOption {
      type = types.bool;
      default = config.services.clightning.tor.proxy;
      description = ''
        Whether to proxy outgoing connections with Tor.
        Warning: When disabled, option {option}`services.clightning.tor.enforce` is
        automatically disabled for the whole clightning service, because
        trustedcoin needs clearnet HTTPS connections to its block explorers.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.clightning = {
      useBcliPlugin = false;
      pluginsConfig = ''
        plugin=${cfg.package}/bin/trustedcoin
      '';
      # Without the proxy, trustedcoin needs clearnet access. This drops
      # enforcement for the whole clightning unit, see the option descriptions.
      tor.enforce = mkIf (!cfg.tor.proxy) false;
    };

    systemd.services.clightning.environment = mkIf (cfg.tor.proxy) {
      HTTPS_PROXY = let
        clnProxy = config.services.clightning.proxy;
        proxy = if clnProxy != null then clnProxy else config.nix-bitcoin.torClientAddressWithPort;
      in
        "socks5://${proxy}";
    };
  };
}
