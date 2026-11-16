{ config, lib, pkgs, ... }:

with lib;
let
  options.services.charge-lnd = with types; {
    enable = mkEnableOption "charge-lnd, policy-based fee manager";

    extraFlags = mkOption {
      type = listOf str;
      default = [];
      example = [ "--verbose" "--dry-run" ];
      description = "Extra flags to pass to the charge-lnd command.";
    };

    interval = mkOption {
      type = str;
      default = "*-*-* 04:00:00";
      example = "hourly";
      description = ''
        Systemd calendar expression when to adjust fees.

        See {man}`systemd.time(7)` for possible values.

        Default is once a day.
      '';
    };

    randomDelay = mkOption {
      type = str;
      default = "1h";
      description = ''
        Random delay to add to scheduled time.
      '';
    };

    policies = mkOption {
      type = types.lines;
      default = "";
      example = ''
        [discourage-routing-out-of-balance]
        chan.max_ratio = 0.1
        chan.min_capacity = 250000
        strategy = static
        base_fee_msat = 10000
        fee_ppm = 500

        [encourage-routing-to-balance]
        chan.min_ratio = 0.9
        chan.min_capacity = 250000
        strategy = static
        base_fee_msat = 1
        fee_ppm = 2

        [default]
        strategy = ignore
      '';
      description = ''
        Policy definitions in INI format.

        See https://github.com/accumulator/charge-lnd/blob/master/README.md#usage
        for possible properties and parameters.

        Policies are evaluated from top to bottom.
        The first matching policy (or `default`) is applied.
      '';
    };
  };

  cfg = config.services.charge-lnd;
  nbLib = config.nix-bitcoin.lib;

  lnd = config.services.lnd;

  user = "charge-lnd";
  group = user;
  configFile = builtins.toFile "charge-lnd.config" cfg.policies;
  checkedConfig = pkgs.runCommand "charge-lnd-checked.config" { } ''
    ${config.nix-bitcoin.pkgs.charge-lnd}/bin/charge-lnd --check --config ${configFile}
    cp ${configFile} $out
  '';
in
{
  inherit options;

  config = mkIf cfg.enable {
    services.lnd = {
      enable = true;
      macaroons.charge-lnd = {
        user = user;
        # offchain:write would also allow sending payments and abandoning channels.
        # Restrict writes to the two RPCs used to manage channel policies.
        permissions = ''
          {"entity":"info","action":"read"},
          {"entity":"onchain","action":"read"},
          {"entity":"offchain","action":"read"},
          {"entity":"uri","action":"/lnrpc.Lightning/UpdateChannelPolicy"},
          {"entity":"uri","action":"/routerrpc.Router/UpdateChanStatus"}
        '';
      };
    };

    systemd.services.charge-lnd = {
      documentation = [ "https://github.com/accumulator/charge-lnd/blob/master/README.md" ];
      after = [ "lnd.service" ];
      requires = [ "lnd.service" ];
      serviceConfig = nbLib.defaultHardening // {
        ExecStart = ''
          ${config.nix-bitcoin.pkgs.charge-lnd}/bin/charge-lnd \
            --tlscert ${escapeShellArg lnd.certPath} \
            --macaroon /run/lnd/charge-lnd.macaroon \
            --grpc ${nbLib.addressWithPort lnd.rpcAddress lnd.rpcPort} \
            --config ${checkedConfig} \
            ${escapeShellArgs cfg.extraFlags}
        '';
        Type = "oneshot";
        User = user;
        Group = group;
      } // nbLib.allowLocalIPAddresses;
    };

    systemd.timers.charge-lnd = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        RandomizedDelaySec = cfg.randomDelay;
      };
    };

    users.users.${user} = {
      isSystemUser = true;
      group = group;
    };
    users.groups.${group} = {};
  };
}
