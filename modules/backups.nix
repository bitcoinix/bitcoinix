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

        If a database dump or a wallet/mint snapshot fails, the `duplicity` unit
        still backs up all other files and then fails.

        When cdk-mintd is enabled, briefly stop it to snapshot its complete data
        directory and signing secrets, then restart it if it was running. Only
        the staged copy is archived, never the live mint databases.

        The backup leaves out the Lightning channel databases, because restoring a
        copy of them can lose all funds in their channels. See
        docs/service/backups.md.

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

  # duplicity reads each line as a glob. A one-char class matches the char itself.
  escapeGlob = replaceStrings [ "[" "*" "?" ] [ "[[]" "[*]" "[?]" ];

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
    # Relative wallet paths start in the network dir. Match every network so a
    # switch cannot put a previous network's database back in the archive.
    walletGlob = path: normalisePath (
      if hasPrefix "/" path then escapeGlob path else "${escapeGlob clightning.dataDir}/*/${escapeGlob path}"
    );
    localDir = replication.local.directory;
    localReplicas = optionals (localDir != null) (map (name: "${localDir}/${name}")
      (attrValues (import ./clightning-replica-files.nix)));
    dbGlobs = unique (map walletGlob ([ "lightningd.sqlite3" ] ++ walletPaths ++ localReplicas));
  in concatMap (db: [ db "${db}-*" ]) dbGlobs
    # gocryptfs keeps the encrypted replica in this dir, see ./clightning-replication.nix
    ++ optional (localDir != null) (escapeGlob "${normalisePath localDir}/lightningd-db")
    # The SSHFS and gocryptfs mounts, `mountsDir` in ./clightning-replication.nix
    ++ optional (replication.enable && (replication.sshfs.destination != null || replication.encrypt))
      (escapeGlob "/var/cache/clightning-replication")
    ++ [ (escapeGlob "${normalisePath config.services.lnd.dataDir}/graph") ];

  # duplicity fails on a selection outside its root
  underBackupRoot = path:
    hasPrefix "${escapeGlob (removeSuffix "/" (normalisePath config.services.duplicity.root))}/" path;

  # Potential backup file paths are matched against filelist
  # entries from top to bottom.
  # The first match determines inclusion or exclusion.
  # The channel databases come first, so that `extraFiles` can't include them.
  includeFileList = builtins.toFile "filelist.txt" ''
    ${concatMapStringsSep "\n" (path: "- ${path}") (filter underBackupRoot channelDatabases)}

    ${optionalString mint.enable (concatStringsSep "\n" (
      # Before extraFiles: never include live mint data or partial snapshots.
      optional (underBackupRoot (escapeGlob (normalisePath mint.dataDir))) "- ${escapeGlob (normalisePath mint.dataDir)}"
      ++ optional (underBackupRoot mintBackupDir) "${mintBackupDir}/current"
      ++ optional (underBackupRoot mintBackupDir) "- ${mintBackupDir}"
    ))}

    ${builtins.concatStringsSep "\n" cfg.extraFiles}

    ${optionalString (!cfg.with-bulk-data) (concatMapStringsSep "\n" (dir: ''
      - ${dir}/blocks
      - ${dir}/chainstate
      - ${dir}/indexes
    '') bulkDataDirs)}
    ${config.services.bitcoind.dataDir}
    ${config.services.clightning.dataDir}
    ${config.services.lnd.dataDir}
    ${optionalString config.services.unbeholden-lnurl.enable config.services.unbeholden-lnurl.dataDir}
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
  # Inactive public chains can still occupy the data directory after a switch.
  # Regtest blocks remain part of the backup.
  bulkDataDirs = [ bitcoind.dataDir "${bitcoind.dataDir}/signet" "${bitcoind.dataDir}/testnet4" ];
  walletBackupDir = "${bitcoind.dataDir}/wallet-backups";
  backupWallets = bitcoind.enable && bitcoind.disablewallet != true;
  # The bitcoind-remote preset replaces the daemon with a oneshot unit, and the
  # wallets live on the remote node. Don't use this to decide whether a
  # `systemd.services` attribute exists, which would recurse.
  localBitcoind = config.systemd.services.bitcoind.serviceConfig.Type == "notify";
  backupWalletsScript = let
    # Skip `bitcoin.conf`. Older versions let the operator replace that file in the
    # data dir.
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

  mint = config.services.cdk-mintd;
  mintBackupDir = "/var/lib/cdk-mintd-backup";
  mintBackupRuntimeDir = "/run/cdk-mintd-backup";
  mintBackupLock = "/run/lock/cdk-mintd-backup.lock";
  asMint = "setpriv --reuid=${escapeShellArg mint.user} --regid=${escapeShellArg mint.group} --init-groups --";
  mintBackupManifest = pkgs.writeText "cdk-mintd-backup-manifest.json" (builtins.toJSON {
    format = 1;
    inherit (mint) dataDir seedFile;
    mnemonicFile = if mint.onchain.enable then mint.onchain.mnemonicFile else null;
  });
  # These two directories must not overlap: staging removes old snapshots.
  overlapsMintStaging = path: let
    p = normalisePath path;
  in p == "/" || p == mintBackupDir || hasPrefix "${mintBackupDir}/" p || hasPrefix "${p}/" mintBackupDir;

  dumpServices = postgresqlBackupServices
    ++ optional (backupWallets && localBitcoind) "bitcoind-wallet-backup.service"
    ++ optional mint.enable "cdk-mintd-backup.service";
in {
  inherit options;

  config = mkIf cfg.enable {
      assertions = optional mint.enable {
        assertion = !any overlapsMintStaging ([ mint.dataDir mint.seedFile ]
          ++ optional mint.onchain.enable mint.onchain.mnemonicFile);
        message = "cdk-mintd data and secrets must not overlap ${mintBackupDir}, which is reserved for backup staging.";
      };

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
          ${optionalString mint.enable ''
            # Also invalidate the previous snapshot if the dump unit cannot
            # start at all (masked, start-limited or failing unit setup).
            rm -rf -- ${mintBackupDir}/current
          ''}
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
          # Invalidate old mint snapshots inside duplicity's read-only sandbox.
          # The staging directory may not exist before the first backup.
          ReadWritePaths = optional mint.enable "-${mintBackupDir}";
        };
      };

      systemd.tmpfiles.rules = optional backupWallets
        "d '${walletBackupDir}' 0700 ${bitcoind.user} ${bitcoind.group} - -"
        ++ optional mint.enable "f ${mintBackupLock} 0600 root root - -";

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

      # Remember starts during a copy instead of silently dropping them. The
      # lock serializes start requests with creating/removing the backup marker.
      # It is never held while waiting for a mint start/stop job.
      systemd.services.cdk-mintd = mkIf mint.enable {
        serviceConfig.ExecCondition = nbLib.rootScript "cdk-mintd-backup-condition" ''
          exec 9>${mintBackupLock}
          ${pkgs.util-linux}/bin/flock 9
          if [[ -e ${mintBackupRuntimeDir}/in-progress ]]; then
            touch ${mintBackupRuntimeDir}/restart
            exit 1
          fi
        '';
      };

      systemd.services.cdk-mintd-backup = mkIf mint.enable {
        description = "Stage consistent CDK mint data and signing secrets for backup";
        after = [ "nix-bitcoin-secrets.target" ];
        path = [ config.systemd.package pkgs.util-linux pkgs.gnutar ];
        script = ''
          export HOME=/var/empty
          umask 077
          # A failed run must not leave yesterday's copy looking current.
          rm -rf -- "$STATE_DIRECTORY/current" "$STATE_DIRECTORY/.next"
          exec 9>${mintBackupLock}
          flock 9
          touch "$RUNTIME_DIRECTORY/in-progress"
          state=$(systemctl is-active cdk-mintd.service) || true
          case $state in
            active|activating|reloading) touch "$RUNTIME_DIRECTORY/restart" ;;
            inactive|failed) ;;
            *) echo "Error: cdk-mintd is $state" >&2; exit 1 ;;
          esac
          # A start waiting for its backend still has ActiveState=inactive.
          job=$(systemctl show -p Job --value cdk-mintd.service)
          if [[ -n $job && $job != 0 ]]; then
            touch "$RUNTIME_DIRECTORY/restart"
          fi
          flock -u 9
          systemctl stop cdk-mintd.service

          mkdir "$STATE_DIRECTORY/.next"
          # The mint can write its data dir, so root must not traverse it.
          # tar preserves symlinks without following them; the only files root
          # writes have fixed names inside its own private staging directory.
          ${asMint} \
            tar --sparse -C ${escapeShellArg mint.dataDir} -cf - . > "$STATE_DIRECTORY/.next/data.tar"
          ${asMint} \
            cat -- ${escapeShellArg mint.seedFile} > "$STATE_DIRECTORY/.next/seed"
          test -s "$STATE_DIRECTORY/.next/seed"
          ${optionalString mint.onchain.enable ''
            ${asMint} \
              cat -- ${escapeShellArg mint.onchain.mnemonicFile} > "$STATE_DIRECTORY/.next/bdk-mnemonic"
            test -s "$STATE_DIRECTORY/.next/bdk-mnemonic"
          ''}
          cp ${mintBackupManifest} "$STATE_DIRECTORY/.next/manifest.json"
          date --iso-8601=seconds > "$STATE_DIRECTORY/.next/created-at"
          mv -T "$STATE_DIRECTORY/.next" "$STATE_DIRECTORY/current"
        '';
        # Runs on success, failure and cancellation, even if the main script
        # was killed. Queue the restart without making a good snapshot depend
        # on the mint or its backend successfully starting.
        postStop = ''
          rm -rf -- "$STATE_DIRECTORY/.next"
          exec 9>${mintBackupLock}
          flock 9
          rm -f -- "$RUNTIME_DIRECTORY/in-progress"
          if [[ -e $RUNTIME_DIRECTORY/restart ]]; then
            systemctl start --no-block cdk-mintd.service || \
              echo "Could not queue cdk-mintd restart; check its journal." >&2
          fi
        '';
        serviceConfig = nbLib.defaultHardening // {
          Type = "oneshot";
          StateDirectory = "cdk-mintd-backup";
          StateDirectoryMode = "0700";
          RuntimeDirectory = "cdk-mintd-backup";
          RuntimeDirectoryMode = "0700";
          ReadWritePaths = [ mintBackupLock ];
          UMask = "0077";
          TimeoutStartSec = "15min";
          PrivateNetwork = true;
          RestrictAddressFamilies = "AF_UNIX";
          # Drop to the real mint uid/gid for every read of mint-owned files.
          PrivateUsers = false;
          CapabilityBoundingSet = [ "CAP_SETUID" "CAP_SETGID" ];
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
