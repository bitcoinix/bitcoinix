# You can run this test via `run-tests.sh -s wireguard-lndconnect`

makeTestVM: pkgs:
with pkgs.lib;

let
  # A port that NixOS opens on all interfaces, which `restrictPeer` must still guard
  globalPort = 2222;
in
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

      networking.firewall.allowedTCPPorts = [ globalPort ];
      systemd.services.global-port-listener = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server --bind 0.0.0.0 ${toString globalPort}";
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

      with subtest("REST accept rules only match traffic from wg-nb"):
          lnd_rest_port = parse_lndconnect_url(
              server.succeed("runuser -u operator -- lndconnect-wg --url")
          ).port
          dport = f"--dport {lnd_rest_port}"
          rules = server.succeed("iptables -w -S nixos-fw").splitlines()
          assert any("-i wg-nb" in r and dport in r for r in rules), \
              f"no wg-nb pinned accept rule for port {lnd_rest_port}:\n" + "\n".join(rules)

          def packets(*match):
              out = server.succeed("iptables -w -L nixos-fw -v -x -n").splitlines()
              lines = [l for l in out if all(m in l for m in match)]
              assert len(lines) == 1, f"expected one rule matching {match}, got {lines}"
              return int(lines[0].split()[0])

          # Spoof a WireGuard subnet source over the plain test network (eth1).
          # Use `.3` instead of the peer address `.2`, so the client's tunnel
          # address and routing stay untouched. The accept rules match the whole /24.
          spoofed = "10.10.0.3"
          dpt = f"dpt:{lnd_rest_port}"
          # Bypass the reverse path filter, which would drop the spoofed packet
          # before it reaches `nixos-fw`, so that the `-i wg-nb` pin is what is tested.
          server.succeed("iptables -w -t mangle -D PREROUTING -j nixos-fw-rpfilter")
          # Count spoofed packets that reach `nixos-fw` (rule without a target)
          server.succeed(f"iptables -w -I nixos-fw 1 -p tcp -s {spoofed} --dport {lnd_rest_port}")
          client.succeed(f"ip addr add {spoofed}/32 dev eth1")
          try:
              server.succeed("iptables -w -Z nixos-fw")
              # The curl fails on the old `-s`-only rules too: the server's reply
              # goes into `wg-nb`, so only the packet counters show the difference.
              client.fail(
                  f"curl -4 -fsS --max-time 3 --insecure --interface {spoofed} "
                  f"https://server:{lnd_rest_port}/v1/getinfo"
              )
              assert packets(spoofed, dpt) > 0, "spoofed packets did not reach nixos-fw"
              assert packets("nixos-fw-accept", "wg-nb", dpt) == 0, \
                  "spoofed packets were accepted by the wg-nb rule"
          finally:
              client.succeed(f"ip addr del {spoofed}/32 dev eth1")
              server.succeed(f"iptables -w -D nixos-fw -p tcp -s {spoofed} --dport {lnd_rest_port}")
              server.succeed("iptables -w -t mangle -A PREROUTING -j nixos-fw-rpfilter")

          # The tunnel still works
          client.succeed("ping -c 1 -W 0.5 10.10.0.1")

      with subtest("restrictPeer rejects peer traffic to globally opened ports"):
          reject = ["-s 10.10.0.2/32", "! -d 10.10.0.1/32", "-j REJECT"]
          for chain in ["nixos-fw", "FORWARD"]:
              first = server.succeed(f"iptables -w -S {chain} 1")
              assert all(m in first for m in reject), \
                  f"restrictPeer rule is not first in {chain}: {first}"

          port = ${toString globalPort}
          server.wait_for_unit("global-port-listener.service")
          server.wait_for_open_port(port)
          server_ip = server.succeed(
              "ip -4 -o addr show dev eth1 | awk '{print $4}' | cut -d/ -f1"
          ).strip()
          # The port is open on the plain test network
          client.succeed(f"curl -fsS --max-time 3 -o /dev/null http://{server_ip}:{port}/")

          def reject_packets():
              out = server.succeed("iptables -w -L nixos-fw -v -x -n").splitlines()
              lines = [l for l in out if "REJECT" in l and "10.10.0.2" in l and "!10.10.0.1" in l]
              assert len(lines) == 1, f"expected one restrictPeer rule, got {lines}"
              return int(lines[0].split()[0])

          # Give the server a second non-tunnel address and route it through the tunnel.
          # Don't route `server_ip`: it can be the tunnel's own endpoint.
          other_ip = "192.0.2.1"
          server.succeed(f"ip addr add {other_ip}/32 dev eth1")
          peer = client.succeed("wg show wireguard peers").strip()
          client.succeed(f"wg set wireguard peer {peer} allowed-ips 10.10.0.0/24,{other_ip}/32")
          client.succeed(f"ip route add {other_ip}/32 dev wireguard src 10.10.0.2")
          api = parse_lndconnect_url(server.succeed("runuser -u operator -- lndconnect-wg --url"))
          probes = {
              "global port": f"curl -fsS --max-time 3 -o /dev/null http://{other_ip}:{port}/",
              # No `-f`: any HTTP response, even an auth error, means the port was reached
              "lnd REST": f"curl -sS --max-time 3 --insecure -o /dev/null https://{other_ip}:{api.port}/v1/getinfo",
          }
          try:
              assert "dev wireguard" in client.succeed(f"ip route get {other_ip}")
              for name, probe in probes.items():
                  server.succeed("iptables -w -Z nixos-fw")
                  client.fail(probe)
                  assert reject_packets() > 0, f"{name} probe did not hit the restrictPeer rule"
          finally:
              client.succeed(f"ip route del {other_ip}/32 dev wireguard")
              client.succeed(f"wg set wireguard peer {peer} allowed-ips 10.10.0.0/24")
              server.succeed(f"ip addr del {other_ip}/32 dev eth1")

          # REST on the tunnel address still works
          client.succeed(
              f"curl -fsS --max-time 3 --insecure --header 'Grpc-Metadata-macaroon: {api.macaroon_hex}' "
              f"-X GET https://{api.host}:{api.port}/v1/getinfo"
          )
  '';
}
