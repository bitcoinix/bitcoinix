@test("lndconnect-onion-lnd")
def test_lndconnect_onion_lnd():
    assert_running("lnd")
    assert_matches("runuser -u operator -- lndconnect --url", ".onion")


@test("lnconnect-onion-clnrest")
def test_lnconnect_onion_clnrest():
    assert_running("clightning")
    assert_matches("runuser -u operator -- lnconnect-clnrest --url", ".onion")


@test("lnconnect-clnrest-cert")
def test_lnconnect_clnrest_cert():
    assert_running("clightning")
    host = ip("clightning")
    url = urlparse(succeed(f"runuser -u operator -- lnconnect-clnrest --host {host} --url").strip())
    assert url.scheme == "clnrest" and url.hostname == host
    encoded_cert = parse_qs(url.query)["cert"][0]
    url_cert = base64.urlsafe_b64decode(encoded_cert + "===")
    # Compare with the TLS handshake, so a client certificate cannot pass this check.
    server_cert = succeed(
        f"openssl s_client -connect {host}:{url.port} </dev/null 2>/dev/null "
        "| openssl x509 -outform DER | base64 -w0"
    )
    assert url_cert == base64.b64decode(server_cert), "Connection URL contains the wrong TLS certificate"


@test("lndconnect-local-bind")
def test_lndconnect_local_bind():
    for service in test_data["lndconnect-local-bind"]:
        port = service["port"]
        assert_running(service["unit"])
        wait_for_open_port("127.0.0.1", port)
        # The REST server must listen on localhost only
        assert_full_match(
            f"ss -Htnl 'sport = :{port}' | awk '{{print $4}}' | sort -u", f"127.0.0.1:{port}\n"
        )


# Run this test before the following tests that shut down services
# (and their corresponding network namespaces).
@test("netns-isolation")
def test_netns_isolation():
    def get_ips(services):
        enabled = enabled_tests.intersection(services)
        return " ".join(ip(service) for service in enabled)

    def assert_reachable(src, dests):
        dest_ips = get_ips(dests)
        if src in enabled_tests and dest_ips:
            machine.succeed(f"ip netns exec nb-{src} fping -c1 -t100 {dest_ips}")

    def assert_unreachable(src, dests):
        dest_ips = get_ips(dests)
        if src in enabled_tests and dest_ips:
            machine.fail(
                # This fails when no host is reachable within 100 ms
                f"ip netns exec nb-{src} fping -c1 -t100 --reachable=1 {dest_ips}"
            )

    # These reachability tests are non-exhaustive
    assert_reachable("bitcoind", ["clightning", "lnd"])
    assert_unreachable("bitcoind", ["btcpayserver", "rtl"])
    assert_unreachable("btcpayserver", ["bitcoind"])

    # The netns firewall rules are IPv4 only, so the veth inside a netns must
    # have no IPv6 address. Otherwise it is reachable over link-local IPv6
    # from every other netns on the bridge.
    for service in enabled_tests.intersection(test_data["netns"]):
        veth = f"nb-veth-{test_data['netns'][service]['id']}"
        assert_full_match(f"ip netns exec nb-{service} ip -6 addr show dev {veth}", "")

    # netns addresses can not be bound to in the main netns.
    # This prevents processes in the main netns from impersonating nix-bitcoin services.
    assert_matches(
        f"nc -l {ip('bitcoind')} 1080 2>&1 || true", "nc: Cannot assign requested address"
    )
