{ config, lib, pkgs, ... }:

with lib;
let
  options.services.backups = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable backups of node data.
        This uses the NixOS duplicity service.
        To further configure the backup, you can set NixOS options `services.duplicity.*`.
        The `services.duplicity.cleanup.*` options are particularly useful.

        If a database dump or a bitcoind wallet copy fails, the `duplicity` unit
        still backs up all other files and then fails.

        The backup leaves out the Lightning channel databases, because restoring a
        copy of them can lose all funds in their channels. See the Backups section
        in docs/services.md.

        With {option}`nix-bitcoin.generateSecrets`, the backups are encrypted with
        the generated password `backup-encryption-password` in
        {option}`nix-bitcoin.secretsDir`. The backups include it, but you need it
        to decrypt them. Keep a copy off the node.
      '';
    };
    with-bulk-data = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to also backup Bitcoin blockchain and other bulk data.
      '';
    };
    destination = mkOption {
      type = types.str;
      default = "file:///var/lib/localBackups";
      description = ''
        Where to back up to.
      '';
    };
    frequency = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Run backup with the given frequency. If null, do not run automatically.
      '';
    };
    postgresqlDatabases = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        List of database names to backup.
        Don't list the database of Core Lightning when it uses PostgreSQL. A dump is an
        outdated copy of its channel state, and restoring it can lose all funds in its
        channels.
      '';
    };
    extraFiles = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "/var/lib/nginx" ];
      description = "Additional files to be appended to filelist.";
    };
  };

  cfg = config.services.backups;
  nbLib = config.nix-bitcoin.lib;

  # duplicity matches paths as strings, so resolve `.` and `..`
  normalisePath = path: "/" + concatStringsSep "/" (foldl' (parts: part:
    if part == "" || part == "." then parts
    else if part == ".." then (if parts == [] then [] else init parts)
    else parts ++ [ part ]
  ) [] (splitString "/" path));

  # Never back up the Lightning channel databases. The daemons write them while the
  # backup runs, and a node that runs from an outdated copy can broadcast a revoked
  # channel state. The peer can then take all funds in that channel.
  # lnd's `graph` dir holds `channel.db` and its other channel state databases.
  channelDatabases = let
    inherit (config.services) clightning;
    inherit (clightning) replication;
    # Core Lightning's `wallet` can set its own SQLite files, a main database and a
    # replica. Like Core Lightning, split at the first `:` only.
    walletPaths = let
      parts = splitString ":" (removePrefix "sqlite3://" clightning.wallet);
    in filter (path: path != "") (optionals (clightning.wallet != null && hasPrefix "sqlite3://" clightning.wallet)
      ([ (head parts) ] ++ optional (length parts > 1) (concatStringsSep ":" (tail parts))));
    # A relative path starts in the network dir, the working dir of Core Lightning
    absolute = path: normalisePath (if hasPrefix "/" path then path else "${clightning.networkDir}/${path}");
    # duplicity reads each line as a glob. A one-char class matches the char itself.
    escapeGlob = replaceStrings [ "[" "*" "?" ] [ "[[]" "[*]" "[?]" ];
    sqliteFiles = db: let escaped = escapeGlob db; in [ escaped "${escaped}-*" ];
  in concatMap sqliteFiles (unique (map absolute ([ "lightningd.sqlite3" ] ++ walletPaths)))
    # gocryptfs keeps the encrypted replica in this dir, see ./clightning-replication.nix
    ++ optional (replication.enable && replication.encrypt && replication.local.directory != null)
      (escapeGlob "${normalisePath replication.local.directory}/lightningd-db")
    # The SSHFS and gocryptfs mounts, `mountsDir` in ./clightning-replication.nix
    ++ optional (replication.enable && (replication.sshfs.destination != null || replication.encrypt))
      (escapeGlob "/var/cache/clightning-replication")
    ++ [ (escapeGlob "${normalisePath config.services.lnd.dataDir}/graph") ];

  # duplicity fails on a selection outside its root
  underBackupRoot = path:
    hasPrefix "${removeSuffix "/" (normalisePath config.services.duplicity.root)}/" path;

  # Potential backup file paths are matched against filelist
  # entries from top to bottom.
  # The first match determines inclusion or exclusion.
  # The channel databases come first, so that `extraFiles` can't include them.
  includeFileList = builtins.toFile "filelist.txt" ''
    ${concatMapStringsSep "\n" (path: "- ${path}") (filter underBackupRoot channelDatabases)}

    ${builtins.concatStringsSep "\n" cfg.extraFiles}

    ${optionalString (!cfg.with-bulk-data) ''
      - ${config.services.bitcoind.dataDir}/blocks
      - ${config.services.bitcoind.dataDir}/chainstate
      - ${config.services.bitcoind.dataDir}/indexes
    ''}
    ${config.services.bitcoind.dataDir}
    ${config.services.clightning.dataDir}
    ${config.services.lnd.dataDir}
    ${optionalString cfg.with-bulk-data "${config.services.electrs.dataDir}"}
    ${config.services.nbxplorer.dataDir}
    ${config.services.btcpayserver.dataDir}
    ${optionalString config.nix-bitcoin.generateSecrets "${config.nix-bitcoin.secretsDir}"}
    /var/lib/tor
    /var/lib/nixos

    ${builtins.concatStringsSep "\n" postgresqlBackupPaths}

    # Exclude all unspecified files and directories
    - /
  '';

  postgresqlBackupDir = config.services.postgresqlBackup.location;
  # File name suffixes used by the NixOS postgresqlBackup module
  postgresqlBackupSuffix = {
    none = "";
    gzip = ".gz";
    zstd = ".zstd";
  }.${config.services.postgresqlBackup.compression};
  postgresqlBackupPaths = map (db: "${postgresqlBackupDir}/${db}.sql${postgresqlBackupSuffix}") cfg.postgresqlDatabases;
  postgresqlBackupServices = map (db: "postgresqlBackup-${db}.service") cfg.postgresqlDatabases;

  # bitcoind writes the files of loaded wallets while the backup runs, and a copy
  # made during a write is torn. Before each backup, bitcoind writes a consistent
  # copy of each loaded wallet to this dir, which the backup includes with the data dir.
  bitcoind = config.services.bitcoind;
  walletBackupDir = "${bitcoind.dataDir}/wallet-backups";
  backupWallets = bitcoind.enable && bitcoind.disablewallet != true;
  # The bitcoind-remote preset replaces the daemon with a oneshot unit, and the
  # wallets live on the remote node. Don't use this to decide whether a
  # `systemd.services` attribute exists, which would recurse.
  localBitcoind = config.systemd.services.bitcoind.serviceConfig.Type == "notify";
  backupWalletsScript = let
    # Skip `bitcoin.conf`. The operator can replace that file in the data dir and make
    # bitcoin-cli send any file it reads as credentials to any address.
    # bitcoind writes its cookie to /run/bitcoind, see ./bitcoind.nix.
    cli = concatStringsSep " " [
      "${config.nix-bitcoin.pkgs.bitcoind}/bin/bitcoin-cli -noconf"
      "-rpcconnect=${bitcoind.rpc.address} -rpcport=${toString bitcoind.rpc.port}"
      "-rpccookiefile=/run/bitcoind/.cookie"
    ];
    jq = "${pkgs.jq}/bin/jq";
  in ''
    dir='${walletBackupDir}'
    # Only keep files made for this backup. Delete only the files this script writes.
    # The dir can also hold other files, like a wallet of the same name.
    find "$dir" -mindepth 1 -maxdepth 1 -regextype posix-extended -type f \
      -regex '.*/wallet-([0-9a-f]{64}\.dat|names\.json)(\.tmp)?' -delete

    state=$(systemctl is-active bitcoind.service) || true
    case $state in
      active) ;;
      # A stopped bitcoind writes no wallet, so its wallet files are consistent
      inactive|failed) exit 0 ;;
      *) echo "Error: bitcoind is $state" >&2; exit 1 ;;
    esac

    wallets=$(${cli} listwallets)
    mapfile -d "" names < <(${jq} --raw-output0 '.[]' <<< "$wallets")
    status=0
    index='{}'
    for name in "''${names[@]}"; do
      # The hash keeps the file name short for any wallet name
      file=wallet-$(printf '%s' "$name" | sha256sum | cut -d ' ' -f 1).dat
      # A failed copy leaves no file
      if ${cli} -rpcwallet="$name" backupwallet "$dir/$file.tmp"; then
        mv -T "$dir/$file.tmp" "$dir/$file"
        index=$(${jq} --arg file "$file" --arg name "$name" '.[$file] = $name' <<< "$index")
      else
        echo "Error: Can't copy bitcoind wallet '$name'" >&2
        rm -f "$dir/$file.tmp"
        status=1
      fi
    done
    # Lets a restore find the copy of each wallet
    printf '%s\n' "$index" > "$dir/wallet-names.json.tmp"
    mv -T "$dir/wallet-names.json.tmp" "$dir/wallet-names.json"
    exit $status
  '';
  dumpServices = postgresqlBackupServices
    ++ optional (backupWallets && localBitcoind) "bitcoind-wallet-backup.service";
in {
  inherit options;

  config = mkIf cfg.enable {
      environment.systemPackages = [ pkgs.duplicity ];

      services.duplicity = {
        enable = true;
        inherit includeFileList;
        fullIfOlderThan = mkDefault "1M";
        targetUrl = cfg.destination;
        frequency = cfg.frequency;
        secretFile = "${config.nix-bitcoin.secretsDir}/backup-encryption-env";
      };

      systemd.services.duplicity = {
        after = [ "nix-bitcoin-secrets.target" ];
        # Dump the databases and copy the bitcoind wallets before each backup.
        # A failed dump fails the unit, but only after all other files have been
        # backed up, so that a database problem doesn't block e.g. channel backups.
        preStart = ''
          for unit in ${toString dumpServices}; do
            if ! ${config.systemd.package}/bin/systemctl start "$unit"; then
              echo "$unit" >> "$RUNTIME_DIRECTORY/failed-dumps"
            fi
          done
        '';
        postStart = ''
          if [[ -e $RUNTIME_DIRECTORY/failed-dumps ]]; then
            echo "The backup has no current dump of these databases:"
            cat "$RUNTIME_DIRECTORY/failed-dumps"
            exit 1
          fi
        '';
        serviceConfig = {
          # Run postStart after the backup has finished
          Type = "oneshot";
          RuntimeDirectory = "duplicity";
        };
      };

      systemd.tmpfiles.rules = optional backupWallets
        "d '${walletBackupDir}' 0700 ${bitcoind.user} ${bitcoind.group} - -";

      systemd.services.bitcoind-wallet-backup = mkIf backupWallets {
        description = "Copy the loaded bitcoind wallets for the backup";
        enable = localBitcoind;
        script = backupWalletsScript;
        serviceConfig = nbLib.defaultHardening // {
          Type = "oneshot";
          User = bitcoind.user;
          Group = bitcoind.group;
          ReadWritePaths = [ walletBackupDir ];
          # The unit only talks to bitcoind. `localhost` covers an RPC address like 0.0.0.0.
          IPAddressAllow = [ "localhost" bitcoind.rpc.address ];
        };
      };

      services.postgresqlBackup = {
        enable = mkIf (cfg.postgresqlDatabases != []) true;
        databases = cfg.postgresqlDatabases;
      };

      nix-bitcoin.secrets.backup-encryption-env = {
        user = "root";
        # A supplied env file may set nothing, e.g. with duplicity's `--no-encryption`
        allowEmpty = true;
      };
      nix-bitcoin.generateSecretsCmds.backups = ''
        makePasswordSecret backup-encryption-password
        if [[ backup-encryption-password -nt backup-encryption-env ]]; then
           backupPassphrase=$(<backup-encryption-password)
           if [[ ! $backupPassphrase ]]; then
             echo "Error: Secret file 'backup-encryption-password' contains no passphrase" >&2
             exit 1
           fi
           writeSecret backup-encryption-env echo "PASSPHRASE=$backupPassphrase"
        fi
      '';

      # The nbxplorer database holds the private keys of BTCPay hot wallets
      services.backups.postgresqlDatabases = mkIf config.services.btcpayserver.enable [
        "btcpaydb"
        "nbxplorer"
      ];
    };
}
