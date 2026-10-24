{ config, lib, pkgs, ... }:

with lib;
let
  options.services.barkd = {
    enable = mkEnableOption ''
      barkd, the REST daemon of Bark, a wallet for the Ark protocol built by Second.
      Ark lets users hold and send bitcoin off-chain in cooperation with an
      Ark server, while keeping the ability to exit on-chain unilaterally
    '';
    package = mkOption {
      type = types.package;
      default = nbPkgs.bark-wallet;
      defaultText = "config.nix-bitcoin.pkgs.bark-wallet";
      description = "The package providing the `bark` and `barkd` binaries.";
    };
    network = mkOption {
      type = types.enum [ "mainnet" "signet" "mutinynet" "regtest" ];
      default = "signet";
      description = ''
        The Bitcoin network of the wallet.

        Option {option}`services.bitcoind` only supports mainnet and regtest,
        so `signet` and `mutinynet` require {option}`chainSource` `esplora`.
      '';
    };
    arkServer = mkOption {
      type = types.nullOr types.str;
      default = if cfg.network == "signet" then "https://ark.signet.2nd.dev" else null;
      defaultText = ''if network == "signet" then "https://ark.signet.2nd.dev" else null'';
      description = ''
        URL of the Ark server.
        Required for all networks except `signet`, where Second's public
        signet Ark server is used by default.
      '';
    };
    chainSource = mkOption {
      type = types.enum [ "esplora" "bitcoind" ];
      default = "esplora";
      description = ''
        Where barkd gets blockchain data from.

        - `esplora`: An Esplora HTTP API, set via {option}`esploraUrl`.
        - `bitcoind`: The local {option}`services.bitcoind` instance, via its
          `public` RPC user. This enables `txindex` in bitcoind, which Bark requires,
          and requires {option}`network` to match the bitcoind network.
          Bark never sends bitcoind RPC through a proxy, so with
          {option}`tor.proxy` only the Ark server and Esplora connections use Tor.
      '';
    };
    esploraUrl = mkOption {
      type = types.nullOr types.str;
      default = {
        mainnet = "https://mempool.second.tech/api";
        signet = "https://esplora.signet.2nd.dev";
        mutinynet = "https://mutinynet.com/api";
        regtest = null;
      }.${cfg.network};
      defaultText = "A public Esplora instance for the network (none for regtest)";
      description = "URL of the Esplora HTTP API. Only used when {option}`chainSource` is `esplora`.";
    };
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address to listen for REST API connections.";
    };
    port = mkOption {
      type = types.port;
      # barkd's own default (3000) is the default port of RTL
      default = 3030;
      description = "Port to listen for REST API connections.";
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/barkd";
      description = ''
        The data directory for barkd.
        It holds the wallet mnemonic (file `mnemonic`), the wallet database and
        the REST API auth token (file `auth_token`).
      '';
    };
    createWallet = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Create a new wallet with a fresh mnemonic when barkd starts and no wallet exists.
        This requires the Ark server and the chain source to be reachable.

        Disable this to restore a wallet from an existing mnemonic.
        See "Restore a Bark wallet" in docs/services.md.
      '';
    };
    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        vtxo_refresh_expiry_threshold = 288
      '';
      description = ''
        Extra lines appended to the Bark configuration file ({file}`config.toml`).

        See the `Config` struct in
        https://gitlab.com/ark-bitcoin/bark/-/blob/master/bark/src/config.rs
        for all available options.
      '';
    };
    extraArgs = mkOption {
      type = types.separatedString " ";
      default = "";
      description = "Extra command line arguments passed to barkd.";
    };
    user = mkOption {
      type = types.str;
      default = "barkd";
      description = "The user as which to run barkd.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      description = "The group as which to run barkd.";
    };
    cli = mkOption {
      readOnly = true;
      default = pkgs.writers.writeBashBin "barkd-cli" ''
        # Usage: barkd-cli <API path> [curl args...]
        # Example: barkd-cli wallet/balance
        # Switch user because Bark makes the data dir accessible by its owner only.
        set -euo pipefail
        if [[ $# -lt 1 ]]; then
          echo "Usage: barkd-cli <API path below /api/v1/> [curl args...]" >&2
          exit 1
        fi
        path=$1
        shift
        exec ${runAsUser} ${cfg.user} ${pkgs.bash}/bin/bash -c '
          set -euo pipefail
          path=$1
          shift
          # Pass the token via a file descriptor because argv is
          # world-readable through /proc/<pid>/cmdline
          exec ${pkgs.curl}/bin/curl -sS --fail-with-body \
            -H @<(printf "Authorization: Bearer %s\n" "$(cat ${cfg.dataDir}/auth_token)") \
            "http://${nbLib.addressWithPort cfg.address cfg.port}/api/v1/$path" "$@"
        ' barkd-cli "$path" "$@"
      '';
      defaultText = "(See source)";
      description = "Binary to call the barkd REST API as the barkd user.";
    };
    tor = nbLib.tor;
  };

  cfg = config.services.barkd;
  nbLib = config.nix-bitcoin.lib;
  nbPkgs = config.nix-bitcoin.pkgs;
  secretsDir = config.nix-bitcoin.secretsDir;
  runAsUser = config.nix-bitcoin.runAsUserCmd;
  bitcoind = config.services.bitcoind;

  useBitcoind = cfg.chainSource == "bitcoind";
  torProxy = "socks5h://${config.nix-bitcoin.torClientAddressWithPort}";

  configFile = pkgs.writeText "barkd-config.toml" ''
    server_address = "${cfg.arkServer}"
    ${optionalString (!useBitcoind) ''
      esplora_address = "${cfg.esploraUrl}"
    ''}
    ${optionalString useBitcoind ''
      bitcoind_address = "http://${nbLib.addressWithPort bitcoind.rpc.address bitcoind.rpc.port}"
      bitcoind_user = "${bitcoind.rpc.users.public.name}"
    ''}
    ${optionalString cfg.tor.proxy ''
      socks5_proxy = "${torProxy}"
    ''}
    ${cfg.extraConfig}
  '';
in {
  inherit options;

  config = mkIf cfg.enable (mkMerge [
  {
    assertions = [
      { assertion = cfg.arkServer != null;
        message = "services.barkd.arkServer must be set for network `${cfg.network}`.";
      }
      { assertion = useBitcoind || cfg.esploraUrl != null;
        message = "services.barkd.esploraUrl must be set when chainSource is `esplora`.";
      }
      { assertion = !useBitcoind || cfg.network == bitcoind.network;
        message = ''
          services.barkd.network (`${cfg.network}`) must match services.bitcoind.network
          (`${bitcoind.network}`) when services.barkd.chainSource is `bitcoind`.
        '';
      }
      { assertion = !useBitcoind || bitcoind.prune == 0;
        message = "barkd requires bitcoind `txindex`, which does not support pruning.";
      }
    ];

    environment.systemPackages = [ cfg.package (hiPrio cfg.cli) ];

    systemd.tmpfiles.rules = [
      # Bark requires the data dir to be accessible by its owner only
      "d '${cfg.dataDir}' 0700 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.barkd = {
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "nix-bitcoin-secrets.target" ];
      preStart = ''
        # Build the whole config first, then replace the file in one step.
        # The data dir is writable by the service user, so a redirect into
        # `config.toml` could follow a symlink.
        conf=$(
          cat '${configFile}'
          ${optionalString useBitcoind ''
            echo "bitcoind_pass = \"$(cat '${secretsDir}/bitcoin-rpcpassword-public')\""
          ''}
        )
        install -T -m 600 <(echo "$conf") '${cfg.dataDir}/config.toml'

        ${optionalString cfg.createWallet ''
          if [[ ! -e '${cfg.dataDir}/mnemonic' ]]; then
            echo "Create Bark wallet"
            # Without config flags, `bark create` uses the existing config.toml
            ${cfg.package}/bin/bark --datadir '${cfg.dataDir}' --no-logfile \
              create --${cfg.network}
          fi
        ''}
      '';
      serviceConfig = nbLib.defaultHardening // {
        ExecStart = ''
          ${cfg.package}/bin/barkd \
          --datadir '${cfg.dataDir}' \
          --host ${cfg.address} \
          --port ${toString cfg.port} \
          ${cfg.extraArgs}
        '';
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = "10s";
        # Wallet creation and the initial sync need network round trips
        TimeoutStartSec = "5min";
        ReadWritePaths = [ cfg.dataDir ];
      } // nbLib.allowedIPAddresses cfg.tor.enforce;
      # TODO-EXTERNAL:
      # `socks5_proxy` in config.toml doesn't cover the chain source client that
      # wallet creation uses (`bark create` and the REST `wallet/create`), so
      # creation would contact Esplora directly. That client honours the standard
      # proxy variables, so set them until Bark passes `socks5_proxy` there.
      # The bitcoind RPC client never uses a proxy (bark/src/chain.rs), so the
      # local bitcoind stays reachable with netns-isolation. `NO_PROXY` keeps the
      # local and netns addresses direct in any case.
      environment = mkIf cfg.tor.proxy {
        ALL_PROXY = torProxy;
        NO_PROXY = "localhost,127.0.0.1,::1,169.254.0.0/16";
      };
    };

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      extraGroups = optional useBitcoind "bitcoinrpc-public";
    };
    users.groups.${cfg.group} = {};
    nix-bitcoin.operator = {
      groups = [ cfg.group ];
      # Used by `barkd-cli`
      allowRunAsUsers = [ cfg.user ];
    };
  }

  (mkIf useBitcoind {
    services.bitcoind = {
      enable = true;
      txindex = true;
      # Bark submits exit and CPFP transactions as packages
      rpc.users.public.rpcwhitelist = [ "submitpackage" ];
    };

    systemd.services.barkd = {
      # See ./electrs.nix for why barkd is wanted by bitcoind
      wantedBy = [ "bitcoind.service" ];
      requires = [ "bitcoind.service" ];
      after = [ "bitcoind.service" ];
    };
  })
  ]);
}
