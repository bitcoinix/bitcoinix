@test("lndconnect-onion-lnd")
def test_lndconnect_onion_lnd():
    assert_running("lnd")
    assert_matches("runuser -u operator -- lndconnect --url", ".onion")


@test("lnconnect-onion-clnrest")
def test_lnconnect_onion_clnrest():
    assert_running("clightning")
    # lnconnect-clnrest reads the address that onion-addresses publishes, and
    # nothing orders clightning after that service
    machine.wait_for_unit("onion-addresses")
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

    if "unbeholden-lnurl" in enabled_tests:
        backend = "lnd" if test_data["unbeholden-lnurl"]["backend"] == "lnd" else "clightning"
        assert_reachable("unbeholden-lnurl", [backend])
        assert_unreachable("unbeholden-lnurl", ["bitcoind"])
        assert_unreachable("bitcoind", ["unbeholden-lnurl"])

    # These reachability tests are non-exhaustive
    assert_reachable("bitcoind", ["clightning", "lnd"])
    assert_unreachable("bitcoind", ["btcpayserver", "rtl"])
    assert_unreachable("btcpayserver", ["bitcoind"])

    # With br_netfilter loaded (e.g. by Docker), traffic between namespaces
    # passes the host's nat table and FORWARD chain. It must keep its source
    # address, and allowed connections must keep working.
    succeed("modprobe br_netfilter")
    assert_reachable("bitcoind", ["clightning", "lnd"])
    assert_unreachable("bitcoind", ["btcpayserver", "rtl"])
    assert_unreachable("btcpayserver", ["bitcoind"])
    succeed("rmmod br_netfilter")

    # The netns firewall rules are IPv4 only, so the veth inside a netns must
    # have no IPv6 address. Otherwise it is reachable over link-local IPv6
    # from every other netns on the bridge.
    for service in enabled_tests.intersection(test_data["netns"]):
        veth = f"nb-veth-{test_data['netns'][service]['id']}"
        assert_full_match(f"ip netns exec nb-{service} ip -6 addr show dev {veth}", "")

    # The netns scenarios turn MPTCP off on the host, and every service
    # namespace must inherit that, including the ones without a test of their own.
    # Timer-started services like charge-lnd have no namespace yet, so check the
    # namespaces that exist.
    namespaces = succeed("ip netns list | cut -d' ' -f1").split()
    assert "nb-bitcoind" in namespaces, namespaces
    for ns in [f"nb-{service}" for service in test_data["netns"]]:
        if ns in namespaces:
            assert_full_match(f"ip netns exec {ns} cat /proc/sys/net/mptcp/enabled", "0\n")

    # netns addresses can not be bound to in the main netns.
    # This prevents processes in the main netns from impersonating nix-bitcoin services.
    assert_matches(
        f"nc -l {ip('bitcoind')} 1080 2>&1 || true", "nc: Cannot assign requested address"
    )


# Services with `tor.enforce`, and charge-lnd, reach only localhost and, with
# netns-isolation, their namespace subnet, and can't use the local resolver
# sockets (nscd, systemd-resolved, D-Bus). `test_data["tor-enforce"]` selects the
# enabled units with this restriction, running or not.
@test("tor-enforce")
def test_tor_enforce():
    data = test_data["tor-enforce"]
    units = data["selected"]
    # The restricted units are exactly the expected ones. A unit that lost both
    # parts of the restriction isn't selected, and a newly restricted unit must
    # be added to `expected` in tests.nix.
    missing = set(data["expected"]) - set(units)
    unexpected = set(units) - set(data["expected"])
    assert not missing and not unexpected, (
        f"missing: {sorted(missing)}, unexpected: {sorted(unexpected)}"
    )
    # A custom unit with the restriction, defined in every scenario (tests.nix)
    custom = "nb-tor-enforce-custom"

    def show(unit, prop):
        return succeed(f"systemctl show -P {prop} {unit}.service").strip()

    # Directories masked with fail-closed (no `-`) entries; each must be present
    # and hidden.
    masks = ["/run/nscd", "/run/systemd/resolve", "/run/dbus"]

    # Check each unit's own properties before setting up the probes, so a unit
    # that lost its deny rule, allow list or masks fails here.
    # `IPAddressDeny=any` shows as below.
    restrictions = {}
    for unit in units:
        deny = show(unit, "IPAddressDeny")
        assert set(deny.split()) == {"0.0.0.0/0", "::/0"}, f"{unit} IPAddressDeny={deny!r}"
        allow = show(unit, "IPAddressAllow")
        nets = {
            ipaddress.ip_network(a, strict=False)
            for a in data["allow"] + data["extraAllow"].get(unit, [])
        }
        # systemd drops entries covered by a broader one
        expected_allow = {
            n.with_prefixlen for n in nets
            if not any(
                m.version == n.version and m.prefixlen < n.prefixlen and n.network_address in m
                for m in nets
            )
        }
        assert set(allow.split()) == expected_allow, f"{unit} IPAddressAllow={allow!r}"
        inaccessible = show(unit, "InaccessiblePaths")
        for m in masks:
            assert m in inaccessible.split(), f"{unit} doesn't mask {m}: {inaccessible!r}"
        restrictions[unit] = (deny, allow, inaccessible)

    # The masked directories exist on every node, so a unit with the restriction
    # starts also when no service enforces Tor.
    assert_running(custom)

    # A link-local address outside any netns subnet, used as a blocked target.
    blocked = "169.254.169.254"
    netns = test_data.get("netns") or {}
    if any(a["address"].split(".")[2] == "169" for a in netns.values()):
        blocked = "169.254.168.254"
    port = 18080
    listener = "nb-tor-enforce-listener"
    succeed(
        f"ip addr add {blocked}/32 dev lo",
        f"systemd-run --unit={listener} $(command -v nc) -lk {port}",
    )
    wait_for_open_port(blocked, port)

    # A host-side marker in each masked directory shows the mask actually applies.
    marker = ".nb-tor-enforce-marker"
    for m in masks:
        succeed(f"touch {m}/{marker}")
    sockets = {
        "/run/nscd/socket",
        "/run/systemd/resolve/io.systemd.Resolve",
        "/run/dbus/system_bus_socket",
    }

    # 1. Replay each unit's own IP filter and masks in a transient unit, so
    #    stopped and oneshot units (charge-lnd, electrs) are covered too.
    replay_script = (
        f"nc -z -w2 127.0.0.1 {port} || exit 11; "          # localhost allowed
        f"! nc -z -w2 {blocked} {port} || exit 12; "         # other addresses denied
        "getent hosts localhost >/dev/null || exit 13; "     # in-process NSS still works
        + "".join(f"! test -e {m}/{marker} || exit 14; " for m in masks)  # masks hide
        + "true"
    )
    for unit, (deny, allow, inaccessible) in restrictions.items():
        props = (
            # Transient units get the manager's minimal PATH, without nc/getent
            "--setenv=PATH=/run/current-system/sw/bin "
            f"-p {shlex.quote('IPAddressDeny=' + deny)} "
            f"-p {shlex.quote('IPAddressAllow=' + allow)} "
            f"-p {shlex.quote('InaccessiblePaths=' + inaccessible)}"
        )
        succeed(f"systemd-run --wait --collect {props} sh -c {shlex.quote(replay_script)}")
    machine.log(f"tor-enforce: replayed the filter and masks of {units}")

    # 2. For units actually running, probe their real cgroup and mount namespace.
    running = [u for u in units if show(u, "MainPID") != "0"]

    def live_probe():
        for unit in running:
            cgroup = show(unit, "ControlGroup")
            # Join the unit's cgroup (host mount ns: cgroupfs is writable there),
            # which applies its IP filter to the probe.
            probe = (
                f'echo $$ > "/sys/fs/cgroup{cgroup}/cgroup.procs" || exit 10; '
                f"nc -z -w2 127.0.0.1 {port} || exit 11; "
                f"! nc -z -w2 {blocked} {port}"
            )
            succeed(f"sh -c {shlex.quote(probe)}")
            pid = show(unit, "MainPID")
            # Inside the unit's mount ns: the resolver sockets are shadowed, and
            # localhost still resolves from /etc/hosts.
            for sock in sockets:
                if machine.execute(f"test -e {sock}")[0] == 0:
                    succeed(f"nsenter -t {pid} -m -- test ! -e {sock}")
            succeed(f"nsenter -t {pid} -m -- getent hosts localhost >/dev/null")

    live_probe()
    # Restarting the resolver must not re-expose its socket in a running unit.
    if machine.execute("systemctl is-enabled nscd")[0] == 0:
        succeed("systemctl restart nscd")
        machine.wait_for_unit("nscd")
        live_probe()

    succeed(f"systemctl stop {listener}", f"ip addr del {blocked}/32 dev lo")
    for m in masks:
        succeed(f"rm -f {m}/{marker}")
    machine.log(f"tor-enforce: probed running units {running}")
