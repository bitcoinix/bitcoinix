def assert_needs_onion_address(command, onion_file):
    """`command` prints no URL without a host while `onion_file` is missing"""
    def run(args, stderr="2>&1"):
        return machine.execute(f"timeout 120 {command} --url {args} {stderr}")

    owner = succeed(f"stat -c %U {onion_file}").strip()
    as_owner = f"runuser -u {owner} --"
    succeed(f"{as_owner} mv -T {onion_file} {onion_file}.orig")
    try:
        # lndconnect takes a `--host` after `--` as no option
        without_host = [run(args) for args in ("", "-- --host 10.0.0.1")]
        # A host in the args needs no onion address. lndconnect removes the quotes of `"10.0.0.1"`.
        with_host = [run(args, "2>/dev/null") for args in ("--host 10.0.0.1", "--host '\"10.0.0.1\"'")]
    finally:
        succeed(f"{as_owner} mv -T {onion_file}.orig {onion_file}")
    for status, output in without_host:
        assert status == 1 and "://" not in output, output
        assert f"Error: Can't read an onion address from {onion_file}" in output, output
    for status, output in with_host:
        assert status == 0 and urlparse(output.strip()).hostname == "10.0.0.1", output
    # An empty host. lndconnect removes the quotes of `""`.
    for args in ("--host=", "--host '\"\"'"):
        status, output = run(args)
        assert status == 1 and "://" not in output and "--host needs a value" in output, output
    assert_matches(f"{command} --url -- --host=", r"[a-z2-7]{56}\.onion")


@test("lndconnect-onion-lnd")
def test_lndconnect_onion_lnd():
    assert_running("lnd")
    # lndconnect reads the address that onion-addresses publishes
    machine.wait_for_unit("onion-addresses")
    assert_matches("runuser -u operator -- lndconnect --url", ".onion")
    onion_file = "/var/lib/onion-addresses/lnd/lnd-rest"
    for command in ("runuser -u operator -- lndconnect", "lndconnect"):
        assert_needs_onion_address(command, onion_file)
    # The onion service forwards to a Unix socket of lnd
    torrc = succeed("systemctl show -P ExecStart tor | grep -oE '/nix/store/[^ ;]+-torrc' | head -1").strip()
    ports = onion_service_ports(succeed(f"cat {torrc}"), "lnd-rest")
    port = test_data["lndconnect-onion-lnd"]["restPort"]
    assert ports == [f"{port} unix:{lnd_rest_socket}"], ports
    assert_lnd_rest_socket()
    assert_no_lnd_rest_access()
    # lnd keeps its TCP listener
    netns = "ip netns exec nb-lnd " if "netns-isolation" in enabled_tests else ""
    assert succeed_json(netns + lnd_rest_state(url=f"https://{ip('lnd')}:{port}"))["state"]


# Impure: stops lnd, and starts it again with a socket left behind
@test("lndconnect-onion-lnd-restart")
def test_lndconnect_onion_lnd_restart():
    # charge-lnd `requires` lnd, so a timer tick would start lnd during the test
    timers = ["charge-lnd.timer"] if "charge-lnd" in enabled_tests else []
    # The preceding tests use up the start limits of lnd and of RTL, which
    # lnd's start starts
    reset = "systemctl reset-failed lnd" + (" rtl" if "rtl" in enabled_tests else "")
    # The preceding tests may have left lnd down
    succeed(reset, "systemctl start lnd")
    wait_for_lnd_server()
    succeed(*[f"systemctl stop {unit}" for unit in timers + ["lnd"]])
    try:
        # lnd removes the socket when it stops
        succeed(f"[[ ! -e {lnd_rest_socket} ]]")
        assert_no_lnd_rest_access()
        # A crash leaves the socket behind. nc can't remove it after a SIGKILL.
        machine.execute(f"runuser -u lnd -- timeout -s KILL 2 nc -lU {lnd_rest_socket}")
        succeed(f"[[ -S {lnd_rest_socket} ]]")
    finally:
        succeed(reset, "systemctl start lnd", *[f"systemctl start {unit}" for unit in timers])
    assert_lnd_rest_socket()


# Only lnd can create entries in this dir, and only lnd and tor can enter it
lnd_rest_socket_dir = "/run/lnd-rest"
lnd_rest_socket = f"{lnd_rest_socket_dir}/rest.sock"


def lnd_rest_state(curl="curl", url=f"--unix-socket {lnd_rest_socket} https://localhost"):
    # lnd's state needs no macaroon
    return f"{curl} -sSk --max-time 10 {url}/v1/state"


def assert_lnd_rest_socket():
    assert_file_metadata(lnd_rest_socket_dir, owner="lnd", group="tor", mode="2750", file_type="directory")
    assert_file_metadata(lnd_rest_socket, owner="lnd", group="tor", mode="660", file_type="socket")
    assert succeed_json(lnd_rest_state())["state"]
    # Connect like tor, as its user and from its mount namespace, where `/`
    # is tor's root dir with the bind mount
    machine.wait_for_unit("tor")
    pid = succeed("systemctl show -P MainPID tor").strip()
    curl = succeed("readlink -f $(command -v curl)").strip()
    as_tor = f"nsenter -t {pid} -m -S $(id -u tor) -G $(id -g tor) --"
    assert succeed_json(f"{as_tor} {lnd_rest_state(curl)}")["state"]


def assert_no_lnd_rest_access():
    for user in ("nobody", "operator"):
        status, output = machine.execute(f"runuser -u {user} -- touch {lnd_rest_socket_dir}/probe 2>&1")
        assert status != 0 and "Permission denied" in output, output
        machine.fail(f"runuser -u {user} -- {lnd_rest_state()}")


def onion_service_ports(torrc, name):
    """The `HiddenServicePort` values of onion service `name` in `torrc`"""
    ports = []
    service_dir = ""
    for line in torrc.splitlines():
        key, _, value = line.partition(" ")
        if key == "HiddenServiceDir":
            service_dir = value
        elif key == "HiddenServicePort" and service_dir == f"/var/lib/tor/onion/{name}":
            ports.append(value)
    return ports


@test("lnconnect-onion-clnrest")
def test_lnconnect_onion_clnrest():
    assert_running("clightning")
    # lnconnect-clnrest reads the address that onion-addresses publishes, and
    # nothing orders clightning after that service
    machine.wait_for_unit("onion-addresses")
    assert_matches("runuser -u operator -- lnconnect-clnrest --url", ".onion")
    assert_needs_onion_address(
        "runuser -u operator -- lnconnect-clnrest", "/var/lib/onion-addresses/operator/clnrest"
    )
    # A user without access to the onion address
    status, output = machine.execute("runuser -u nobody -- timeout 120 lnconnect-clnrest --url 2>&1")
    assert status == 1 and "://" not in output, output
    assert "Can't read an onion address from /var/lib/onion-addresses/nobody/clnrest" in output, output


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


@test("lnconnect-clnrest-files")
def test_lnconnect_clnrest_files():
    # lnconnect-clnrest reads the admin rune and clnrest's cert only from regular
    # files of the clightning user. Root runs it as that user.
    assert_running("clightning")
    data = test_data["clnrest-admin-rune"]
    rune_file, user = data["file"], data["user"]
    onion = test_data["lnconnect-clnrest-files"]["onion"]
    if onion:
        machine.wait_for_unit("onion-addresses")
        args, host = "--url", r"[a-z2-7]{56}\.onion"
    else:
        args, host = f"--host {ip('clightning')} --url", re.escape(ip("clightning"))
    # The cert is only in URLs without onion
    files = [rune_file] + ([] if onion else [clnrest_cert_file(test_data["clightning"], "server.pem")])
    rune = succeed(f"cat {rune_file}").strip()
    canary = "/run/lnconnect-clnrest-test-canary"
    canary_body = base64.b64encode(b"lnconnect-clnrest-test-canary").decode()
    pem = f"-----BEGIN CERTIFICATE-----\n{canary_body}\n-----END CERTIFICATE-----\n"
    for caller in ("root", "operator"):
        command = f"runuser -u {caller} -- lnconnect-clnrest {args}"
        url = urlparse(succeed(command).strip())
        assert re.fullmatch(host, url.hostname) and parse_qs(url.query)["rune"] == [rune], url
        # A file that the caller can read and the clightning user can't
        succeed(f"printf %s {shlex.quote(pem)} | install -o {caller} -m 600 /dev/stdin {canary}")
        for file in files:
            with machine.nested(f"{caller}: {file} links to a file of {caller}"):
                succeed(f"runuser -u {user} -- sh -c 'mv -T {file} {file}.orig && ln -s {canary} {file}'")
                status, output = machine.execute(f"{command} 2>&1")
                succeed(f"runuser -u {user} -- mv -T {file}.orig {file}")
                assert status != 0 and canary_body not in output, output
                assert f"'{file}' isn't a regular file of user {user}" in output, output
                if caller == "root":
                    # As the clightning user, root can't open its own file
                    assert f"{file}: Permission denied" in output, output
        succeed(f"rm {canary}")

    if onion:
        # Root reads the onion address as the clightning user, from that user's copy
        # and not from the operator's
        owners = [user, "operator"]
        onion_file = "/var/lib/onion-addresses/{}/clnrest".format
        fake = "c" * 56 + ".onion"
        succeed(f"install -m 600 <(echo {fake}) {canary}")
        for owner in owners:
            succeed(f"runuser -u {owner} -- sh -c 'mv -T {onion_file(owner)} {onion_file(owner)}.orig && ln -s {canary} {onion_file(owner)}'")
        # Without an address, lnconnect-clnrest fails and prints no URL
        status, output = machine.execute("timeout 120 lnconnect-clnrest --url 2>&1")
        for owner in owners:
            succeed(f"runuser -u {owner} -- mv -T {onion_file(owner)}.orig {onion_file(owner)}")
        succeed(f"rm {canary}")
        assert status == 1 and "://" not in output, output
        assert fake not in output, output
        assert f"{onion_file(user)}: Permission denied" in output, output
        assert f"Can't read an onion address from {onion_file(user)}" in output, output


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


# The host forwards only the traffic of the service namespaces. Network namespaces
# on veth pairs stand in for a host on each of two networks of the node (a, b) and
# for a service namespace without `tor.enforce` on the bridge (inner).
@test("netns-forwarding")
def test_netns_forwarding():
    chain = "nb-netns-forward"
    bridge_ip = test_data["netns-bridge-ip"]
    block = bridge_ip.rsplit(".", 1)[0]
    inner_ip = f"{block}.250"
    a, b, inner = "nbt-a", "nbt-b", "nbt-inner"
    a_ip, b_ip = "10.201.1.2", "10.201.2.2"

    def ping(ns, dest):
        return f"ip netns exec {ns} fping -c1 -t500 {dest}"

    def add_host(ns, veth, net, route):
        succeed(
            f"ip netns add {ns}",
            f"ip link add {veth} type veth peer name eth0 netns {ns}",
            f"ip addr add {net}.1/24 dev {veth}",
            f"ip link set {veth} up",
            f"ip -n {ns} addr add {net}.2/24 dev eth0",
            f"ip -n {ns} link set eth0 up",
            f"ip -n {ns} route add {route} via {net}.1",
        )

    def assert_dropped(src, dest, in_if, out_if):
        # ACCEPT rules ahead of the jump show that only the chain blocks this path
        accept = [f"-i {in_if} -o {out_if} -j ACCEPT", f"-i {out_if} -o {in_if} -j ACCEPT"]
        succeed(*(f"iptables -w -I FORWARD 1 {rule}" for rule in accept))
        machine.wait_until_succeeds(ping(src, dest), timeout=30)
        succeed(*(f"iptables -w -D FORWARD {rule}" for rule in accept))
        machine.fail(ping(src, dest))

    def assert_rules():
        assert_full_match(f"iptables -w -S {chain}", re.escape(
            f"-N {chain}\n"
            f"-A {chain} -i nb-br -j ACCEPT\n"
            f"-A {chain} -o nb-br -m conntrack --ctstate RELATED,ESTABLISHED --ctdir REPLY -j ACCEPT\n"
            f"-A {chain} -j DROP\n"
        ))
        assert_full_match(f"iptables -w -S FORWARD | grep -c -- '-j {chain}$'", "1\n")

    def active_since(unit):
        return int(succeed(f"systemctl show -P ActiveEnterTimestampMonotonic {unit}"))

    try:
        add_host(a, "nb-veth-ta", "10.201.1", "10.201.2.0/24")
        add_host(b, "nb-veth-tb", "10.201.2", "10.201.1.0/24")
        succeed(
            f"ip netns add {inner}",
            f"ip link add nb-veth-ti type veth peer name eth0 netns {inner}",
            "ip link set nb-veth-ti master nb-br",
            "ip link set nb-veth-ti up",
            f"ip -n {inner} addr add {inner_ip}/24 dev eth0",
            f"ip -n {inner} link set eth0 up",
            f"ip -n {inner} route add default via {bridge_ip}",
        )

        # Between two networks of the node
        assert_dropped(a, b_ip, "nb-veth-ta", "nb-veth-tb")
        # A namespace connects out with NAT. a has no route to the bridge subnet,
        # so the reply passes only with NAT and the rule for replies.
        machine.wait_until_succeeds(ping(inner, a_ip), timeout=30)
        # From a network of the node into the bridge subnet
        succeed(f"ip -n {a} route add {block}.0/24 via 10.201.1.1")
        assert_dropped(a, inner_ip, "nb-veth-ta", "nb-br")

        # With br_netfilter (e.g. loaded by Docker), bridged traffic also passes
        # FORWARD. The netns-isolation test checks the traffic between namespaces.
        succeed("modprobe br_netfilter")
        succeed(ping(inner, a_ip))
        machine.fail(ping(a, inner_ip))
        machine.fail(ping(a, b_ip))
        succeed("rmmod br_netfilter")
    finally:
        machine.execute(f"ip netns delete {a}; ip netns delete {b}; ip netns delete {inner}")

    assert_running(chain)
    assert_rules()
    # At boot, the rules exist before forwarding is on and before the bridge starts.
    # The firewall runs first, so the two never run iptables at the same time.
    def started(unit):
        return int(succeed(f"systemctl show -P InactiveExitTimestampMonotonic {unit}"))

    for unit in ["systemd-sysctl", "nb-netns-bridge"]:
        assert 0 < active_since(chain) <= started(unit), (unit, active_since(chain), started(unit))
    assert 0 < active_since("firewall") <= started(chain), (active_since("firewall"), started(chain))

    units = ["nb-netns-bridge", "netns-bitcoind", "bitcoind"]
    before = {unit: active_since(unit) for unit in units}
    # A reload, like a switch that changes the unit, replaces the rules in place
    # and adds the jump if it's missing
    succeed(f"iptables -w -A {chain} -j ACCEPT", f"systemctl reload {chain}")
    assert_rules()
    succeed(f"iptables -w -D FORWARD -j {chain}", f"systemctl reload {chain}")
    assert_rules()
    # A restart of the rules doesn't restart the bridge or the namespaced services
    succeed(f"systemctl restart {chain}")
    assert {unit: active_since(unit) for unit in units} == before
    assert_rules()

    # A stop, like a switch that turns `restrictForwarding` off, removes the rules
    succeed(f"systemctl stop {chain}")
    machine.fail(f"iptables -w -S {chain}")
    machine.fail(f"iptables -w -S FORWARD | grep -- '-j {chain}$'")
    succeed(f"systemctl start {chain}")
    assert_rules()


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
