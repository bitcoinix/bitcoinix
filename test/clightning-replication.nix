# You can run this test via `run-tests.sh -s clightning-replication`

makeTestVM: pkgs:
with pkgs.lib;
let
  keyDir = pkgs.path + "/nixos/tests/initrd-network-ssh";
  keys = {
    server = keyDir + "/ssh_host_ed25519_key";
    client = keyDir + "/id_ed25519";
    serverPub = readFile (keys.server + ".pub");
    clientPub = readFile (keys.client + ".pub");
  };

  clientBaseConfig = {
    imports = [ ../modules/modules.nix ];

    system.switch.enable = true;

    nixpkgs.pkgs = pkgs;

    nix-bitcoin.generateSecrets = true;

    services.clightning = {
      enable = true;
      replication.enable = true;

      # TODO-EXTERNAL:
      # When WAN is disabled, DNS bootstrapping slows down service startup by ~15 s.
      extraConfig = ''
        disable-dns
      '';
    };
  };
in
makeTestVM {
  name = "clightning-replication";

  nodes = let nodes = {
    replicationLocal = {
      imports = [ clientBaseConfig ];
      services.clightning.replication.local.directory = "/var/backup/clightning";
    };

    replicationLocalEncrypted = {
      imports = [ nodes.replicationLocal ];
      services.clightning.replication.encrypt = true;
    };

    replicationRemote = {
      imports = [ clientBaseConfig ];
      nix-bitcoin.generateSecretsCmds.clightning-replication-ssh-key = mkForce ''
        install -m 600 ${keys.client} clightning-replication-ssh-key
      '';
      programs.ssh.knownHosts."server".publicKey = keys.serverPub;
      services.clightning.replication.sshfs.destination = "nb-replication@server:writable";
    };

    replicationRemoteEncrypted = {
      imports = [ nodes.replicationRemote ];
      services.clightning.replication.encrypt = true;
    };

    server = {
      nixpkgs.pkgs = pkgs;

      environment.etc."ssh-host-key" = {
        source = keys.server;
        mode = "400";
      };

      services.openssh = {
        enable = true;
        extraConfig = ''
          Match user nb-replication
            ChrootDirectory /var/backup/nb-replication
            AllowTcpForwarding no
            AllowAgentForwarding no
            ForceCommand internal-sftp
            PasswordAuthentication no
            X11Forwarding no
        '';
        hostKeys = mkForce [
          {
            path = "/etc/ssh-host-key";
            type = "ed25519";
          }
        ];
      };

      users.users.nb-replication = {
        isSystemUser = true;
        group = "nb-replication";
        shell = "${pkgs.coreutils}/bin/false";
        openssh.authorizedKeys.keys = [ keys.clientPub ];
      };
      users.groups.nb-replication = {};

      systemd.tmpfiles.rules = [
        # Because this directory is chrooted by sshd, it must only be writable by user/group root
        "d /var/backup/nb-replication 0755 root root - -"
        "d /var/backup/nb-replication/writable 0700 nb-replication - - -"
      ];
    };
  }; in nodes;

  testScript =  { nodes, ... }: let
    systems = builtins.concatStringsSep ", "
      (mapAttrsToList (name: node: ''"${name}": "${node.system.build.toplevel}"'') nodes);
  in ''
    systems = { ${systems} }

    def switch_to_system(system):
        cmd = f"{systems[system]}/bin/switch-to-configuration test >&2"
        client.succeed(cmd)

    def check_mount_lifecycle(*mountpoints):
        with subtest("the mounts stop cleanly and stop clightning"):
            client.succeed("systemctl stop clightning-replication-mounts")
            for unit in ["clightning", "clightning-replication-mounts"]:
                client.succeed(f"test $(systemctl show -P ActiveState {unit}) = inactive")
            for mountpoint in mountpoints:
                client.fail(f"findmnt --mountpoint {mountpoint}")
            client.succeed("systemctl start clightning")
            client.wait_for_unit("clightning.service")
            client.succeed("runuser -u clightning -- lightning-cli getinfo")
            for mountpoint in mountpoints:
                client.succeed(f"findmnt --mountpoint {mountpoint}")

        with subtest("clightning restarts after a crash"):
            old_pid = int(client.succeed("systemctl show -P MainPID clightning"))
            assert old_pid > 0
            # Kill only lightningd, leaving its plugins to exit as after a crash.
            client.succeed("systemctl kill --kill-whom=main --signal=SIGKILL clightning")
            client.wait_until_succeeds(
                "pid=$(systemctl show -P MainPID clightning); "
                f"test $pid -gt 0 && test $pid -ne {old_pid}",
                timeout=60,
            )
            client.wait_for_unit("clightning.service")
            client.succeed("runuser -u clightning -- lightning-cli getinfo")
            client.succeed("systemctl is-active clightning-replication-mounts")
            for mountpoint in mountpoints:
                client.succeed(f"findmnt --mountpoint {mountpoint}")

    client = replicationLocal

    if not "is_interactive" in vars():
      client.start()
      server.start()

      with subtest("local replication"):
          client.wait_for_unit("clightning.service")
          client.wait_until_succeeds("runuser -u clightning -- ls /var/backup/clightning/lightningd.sqlite3")
          # No other user should be able to read the backup directory
          client.fail("runuser -u bitcoin -- ls /var/backup/clightning")

      # If `switch_to_system` succeeds then all services, including clightning,
      # have started successfully
      switch_to_system("replicationLocalEncrypted")
      with subtest("local replication encrypted"):
          replica_db = "/var/cache/clightning-replication/plaintext/lightningd.sqlite3"
          client.wait_until_succeeds(f"runuser -u clightning -- ls {replica_db}")
          # No other user should be able to read the unencrypted files
          client.fail(f"runuser -u bitcoin -- ls {replica_db}")
          # A gocryptfs has been created
          client.succeed("ls /var/backup/clightning/lightningd-db/gocryptfs.conf")
          check_mount_lifecycle("/var/cache/clightning-replication/plaintext")

      switch_to_system("replicationRemote")
      server.wait_for_unit("sshd.service")
      with subtest("remote replication"):
          replica_db = "/var/cache/clightning-replication/sshfs/lightningd.sqlite3"
          client.wait_until_succeeds(f"runuser -u clightning -- ls {replica_db}")
          # No other user should be able to read the unencrypted files
          client.fail(f"runuser -u bitcoin -- ls {replica_db}")
          # A clighting db exists on the server
          server.succeed("ls /var/backup/nb-replication/writable/lightningd.sqlite3")
          check_mount_lifecycle("/var/cache/clightning-replication/sshfs")

      switch_to_system("replicationRemoteEncrypted")
      with subtest("remote replication encrypted"):
          replica_db = "/var/cache/clightning-replication/plaintext/lightningd.sqlite3"
          client.wait_until_succeeds(f"runuser -u clightning -- ls {replica_db}")
          # No other user should be able to read the unencrypted files
          client.fail(f"runuser -u bitcoin -- ls {replica_db}")
          # A gocryptfs has been created on the server
          server.succeed("ls /var/backup/nb-replication/writable/lightningd-db/gocryptfs.conf")
          check_mount_lifecycle(
              "/var/cache/clightning-replication/plaintext",
              "/var/cache/clightning-replication/sshfs",
          )
  '';
}
