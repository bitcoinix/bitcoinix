# You can run this test via `run-tests.sh -s wireguard-lndconnect`

makeTestVM: pkgs:
with pkgs.lib;

makeTestVM {
  name = "wireguard-lndconnect";

  nodes = {
    server = {
      imports = [
        ../modules/modules.nix
        ../modules/presets/wireguard.nix
      ];

      nixpkgs.pkgs = pkgs;

      nix-bitcoin.generateSecrets = true;
      nix-bitcoin.operator.enable = true;

      services.clightning = {
        enable = true;
        plugins.clnrest = {
          enable = true;
          lnconnect.enable = true;
        };
      };

      services.clightning-rest = {
        enable = true;
        lndconnect.enable = true;
      };
      # TODO-EXTERNAL:
      # When WAN is disabled, DNS bootstrapping slows down service startup by ~15 s.
      services.clightning.extraConfig = ''
        disable-dns
      '';

      services.lnd = {
        enable = true;
        lndconnect.enable = true;
        port = 9736;
      };
    };

    client = {
      nixpkgs.pkgs = pkgs;

      environment.systemPackages = with pkgs; [
        wireguard-tools
      ];
    };
  };

  testScript =  ''
    import base64
    import urllib.parse as Url
    from types import SimpleNamespace

    def parse_lndconnect_url(url):
        u = Url.urlparse(url)
        data = {'host': u.hostname, 'port': u.port}
        queries = Url.parse_qs(u.query)
        if url.startswith("clnrest"):
            data['rune'] = queries['rune'][0]
        else:
            macaroon = queries['macaroon'][0]
            if url.startswith("c-lightning-rest"):
              data['macaroon_hex'] = macaroon
            else:
              # lnd
              data['macaroon_hex'] = base64.urlsafe_b64decode(macaroon + '===').hex().upper()

        return SimpleNamespace(**data)

    client.start()
    server.connect()

    if not "is_interactive" in vars():

      with subtest("connect client to server via WireGuard"):
          server.wait_for_unit("wireguard-wg-nb-peer-peer0.service")

          # Get WireGuard config from server and save it to `/tmp/wireguard.conf` on the client
          wg_config = server.succeed("runuser -u operator -- nix-bitcoin-wg-connect server --text")
          # Encode to base64
          b64 = base64.b64encode(wg_config.encode('utf-8')).decode()
          client.succeed(f"install -m 400 <(echo -n {b64} | base64 -d) /tmp/wireguard.conf")

          # Connect to server via WireGuard
          client.succeed("wg-quick up /tmp/wireguard.conf")

          # Ping server from client
          print(client.succeed("ping -c 1 -W 0.5 10.10.0.1"))

      with subtest("lndconnect-wg"):
          server.wait_for_unit("lnd.service")
          lndconnect_url = server.succeed("runuser -u operator -- lndconnect-wg --url")
          api = parse_lndconnect_url(lndconnect_url)
          # Make lnd REST API call
          client.succeed(
              f"curl -fsS --max-time 3 --insecure --header 'Grpc-Metadata-macaroon: {api.macaroon_hex}' "
              f"-X GET https://{api.host}:{api.port}/v1/getinfo"
          )

      with subtest("lnconnect-clnrest-wg"):
          server.wait_for_unit("clightning.service")
          lndconnect_url = server.succeed("runuser -u operator -- lnconnect-clnrest-wg --url")
          api = parse_lndconnect_url(lndconnect_url)
          # Make clnrest API call
          client.succeed(
              f"curl -fsS --max-time 3 --insecure --header 'rune: {api.rune}' "
              f"-X POST https://{api.host}:{api.port}/v1/getinfo"
          )

      with subtest("lndconnect-clightning-wg"):
          server.wait_for_unit("clightning-rest.service")
          lndconnect_url = server.succeed("runuser -u operator -- lndconnect-clightning-wg --url")
          api = parse_lndconnect_url(lndconnect_url)
          # Make clightning-rest API call
          client.succeed(
              f"curl -fsS --max-time 3 --insecure --header 'macaroon: {api.macaroon_hex}' "
              f"--header 'encodingtype: hex' -X GET https://{api.host}:{api.port}/v1/getinfo"
          )

      with subtest("wg peer unit uses validated pubkey"):
          unit = "wireguard-wg-nb-peer-peer0.service"
          key_file = "/etc/nix-bitcoin-secrets/wg-peer-public-key"
          pubkey = server.succeed(f"cat {key_file}").strip()

          # The unit scripts must not re-execute their own source with the key spliced in
          scripts = server.succeed(
              f"systemctl cat {unit} | sed -nE 's/^Exec(Start|StopPost)=([^ ]+).*/\\2/p'"
          ).split()
          assert len(scripts) == 2, scripts
          for script in scripts:
              server.fail(f"grep -E 'BASH_SOURCE|inPatchedSrc|peer0' {script}")

          # Stop removes the peer, start adds it with the right allowed IPs
          server.succeed(f"systemctl stop {unit}")
          server.fail(f"wg show wg-nb peers | grep -qxF '{pubkey}'")
          server.succeed(f"cp -p {key_file} /tmp/wg-peer-public-key.orig")

          bad_keys = [
              "$(touch /tmp/wg-pwned)",
              f"{pubkey}\ntouch /tmp/wg-pwned",
              f"{pubkey}|touch /tmp/wg-pwned",
              pubkey[:-1],
          ]
          for bad_key in bad_keys:
              b64 = base64.b64encode(bad_key.encode('utf-8')).decode()
              server.succeed(f"echo -n {b64} | base64 -d > {key_file}")
              status, _ = server.execute(f"systemctl start {unit}")
              server.fail("test -e /tmp/wg-pwned")
              assert status != 0, f"{unit} started with malformed key {bad_key!r}"
              # The key check must reject the input, not `wg` itself
              journal = f"journalctl -o cat _SYSTEMD_INVOCATION_ID=$(systemctl show -P InvocationID {unit})"
              server.wait_until_succeeds(
                  f"{journal} | grep -qF 'does not contain a valid WireGuard public key'", timeout=10
              )
              server.fail(f"{journal} | grep -qF 'Key is not the correct length or format'")
              server.succeed(f"systemctl reset-failed {unit}")

          server.succeed(f"cp -p /tmp/wg-peer-public-key.orig {key_file}")
          server.succeed(f"systemctl start {unit}")
          server.succeed(f"wg show wg-nb allowed-ips | grep -qxF '{pubkey}\t10.10.0.2/32'")
  '';
}
