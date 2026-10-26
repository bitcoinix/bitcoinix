@test("bitcoind")
def test_bitcoind():
    assert_running("bitcoind")
    machine.wait_until_succeeds("bitcoin-cli getnetworkinfo")
    info = succeed_json("runuser -u operator -- bitcoin-cli getnetworkinfo")
    assert isinstance(info["version"], int) and info["version"] > 0, info

    # The cookie lives in a runtime directory that only the bitcoin user can write
    cookie = "/run/bitcoind/.cookie"
    assert_file_metadata("/run/bitcoind", owner="bitcoin", group="bitcoin", mode="750")
    assert_file_metadata(cookie, mode="640")
    # Group members can read the cookie
    succeed(f"runuser -u operator -- cat {cookie} >/dev/null")
    # Group members cannot replace it
    machine.fail(f"runuser -u operator -- mv {cookie} {cookie}.moved")
    # No cookie is left in the group-writable data directory
    succeed("! test -e /var/lib/bitcoind/.cookie", "! test -e /var/lib/bitcoind/regtest/.cookie")

    # RPC access for user 'public' should be restricted
    machine.fail(
        "bitcoin-cli -rpcuser=public -rpcpassword=$(cat /secrets/bitcoin-rpcpassword-public) stop"
    )
    machine.wait_until_succeeds(
        log_has_string("bitcoind", "RPC User public not allowed to call method stop")
    )


@test("bitcoind-rest")
def test_bitcoind_rest():
    data = test_data["bitcoind-rest"]
    rest = f"http://{ip('bitcoind')}:{data['rpcPort']}/rest"
    url = f"{rest}/chaininfo.json"
    if not data["enable"]:
        assert_full_match(f"curl -sS -o /dev/null -w '%{{http_code}}' {url}", "404")
        return

    # REST is unauthenticated
    chaininfo = succeed_json(f"runuser -u nobody -- curl -fsS {url}")
    assert chaininfo["chain"] == data["chain"], chaininfo
    # Fetch a block by height, in the binary format electrs uses
    genesis = succeed_json(f"curl -fsS {rest}/blockhashbyheight/0.json")["blockhash"]
    block = succeed_json(f"curl -fsS {rest}/block/{genesis}.json")
    assert block["hash"] == genesis, block
    assert_full_match(f"curl -fsS {rest}/block/{genesis}.bin | wc -c", r"[1-9][0-9]*\n")
    if "netns-isolation" in enabled_tests:
        # Namespaces without a connection to bitcoind can't reach REST
        netns = test_data["netns"]
        unconnected = [
            n for n in enabled_tests.intersection(netns)
            if n != "bitcoind" and n not in netns["bitcoind"]["availableNetns"]
        ]
        for n in unconnected:
            machine.fail(f"ip netns exec nb-{n} curl -fsS --max-time 5 {url}")


@test("electrs")
def test_electrs():
    assert_running("electrs")
    # electrs.toml holds the public RPC password
    toml = "/var/lib/electrs/electrs.toml"
    assert_file_metadata(toml, owner="electrs", mode="600")
    # A file with laxer permissions (created by earlier versions) is replaced
    succeed(f"chmod 644 {toml} && systemctl restart electrs")
    assert_file_metadata(toml, owner="electrs", mode="600")
    # An index without the marker (created by electrs < 0.12) stops the unit
    # without restarts
    marker = succeed("ls /var/lib/electrs/*.bindex").strip()
    machine.wait_until_succeeds(f"test -d {marker.removesuffix('.bindex')}")
    succeed(f"systemctl stop electrs && mv {marker} {marker}.saved")
    succeed("systemctl start electrs")
    # `failed`, not `activating` (auto-restart)
    machine.wait_until_succeeds("[[ $(systemctl show -P ActiveState electrs) == failed ]]")
    assert_full_match("systemctl show -P ExecMainStatus electrs", "78\n")
    machine.wait_until_succeeds(log_has_string("electrs", "contains an index of electrs < 0.12"))
    succeed(f"mv {marker}.saved {marker} && systemctl reset-failed electrs && systemctl start electrs")
    # Not assert_running: the journal now has the failure from above
    machine.wait_for_unit("electrs")
    wait_for_open_port(ip("electrs"), 4224)  # prometeus metrics provider
    # Check RPC connection to bitcoind
    if not "regtest" in enabled_tests:
        machine.wait_until_succeeds(
            log_has_string("electrs", "waiting for 0 blocks to download")
        )


@test("fulcrum")
def test_fulcrum():
    assert_running("fulcrum")
    machine.wait_until_succeeds(log_has_string("fulcrum", "started ok"))
    # fulcrum.conf holds the public RPC password
    conf = "/var/lib/fulcrum/fulcrum.conf"
    assert_file_metadata(conf, owner="fulcrum", mode="600")
    # A file with laxer permissions (created by earlier versions) is replaced
    succeed(f"chmod 644 {conf} && systemctl restart fulcrum")
    assert_file_metadata(conf, owner="fulcrum", mode="600")
    # Later tests expect a started fulcrum, not one that is still starting
    machine.wait_until_succeeds(current_run_log_has_string("fulcrum", "started ok"))


@test("clightning")
def test_clightning():
    assert_running("clightning")
    info = succeed_json("runuser -u operator -- lightning-cli getinfo")
    assert info["id"], info

    enabled_plugins = test_data["clightning-plugins"]
    if enabled_plugins:
        plugin_list = succeed("lightning-cli plugin list")
        plugins = json.loads(plugin_list)["plugins"]
        active = set(plugin["name"] for plugin in plugins if plugin["active"])
        failed = set(enabled_plugins).difference(active)
        if failed:
            raise Exception(
                f"The following clightning plugins are inactive:\n{failed}.\n\n"
                f"Output of 'lightning-cli plugin list':\n{plugin_list}"
            )
        active = [os.path.splitext(os.path.basename(p))[0] for p in enabled_plugins]
        machine.log("\n".join(["Active clightning plugins:", *active]))

        if "feeadjuster" in active:
            # This is a one-shot service, so this command only succeeds if the service succeeds
            succeed("systemctl start clightning-feeadjuster")

    if test_data["clightning-replication"]:
        replica_db = "/var/cache/clightning-replication/plaintext/lightningd.sqlite3"
        succeed(f"runuser -u clightning -- ls {replica_db}")
        # No other user should be able to read the unencrypted files
        machine.fail(f"runuser -u bitcoin -- ls {replica_db}")
        # A gocryptfs has been created
        succeed("ls /var/backup/clightning/lightningd-db/gocryptfs.conf")


@test("lnd")
def test_lnd():
    assert_running("lnd")
    info = succeed_json("runuser -u operator -- lncli getinfo")
    assert info["version"], info
    assert_no_failure("lnd")

    # Test certificate generation
    cert_alt_names = succeed("</secrets/lnd-cert openssl x509 -noout -ext subjectAltName")
    assert_str_matches(cert_alt_names, '10.0.0.1')
    assert_str_matches(cert_alt_names, '20.0.0.1')
    assert_str_matches(cert_alt_names, 'example.com')


@test("charge-lnd")
def test_charge_lnd():
    # charge-lnd is a oneshot service that is started by a timer under regular operation
    succeed("systemctl start charge-lnd")
    assert_no_failure("charge-lnd")

    def request(method, path, *, user="charge-lnd",
                macaroon="/run/lnd/charge-lnd.macaroon", input_cmd="printf '{}'"):
        # Stream bodies and headers so neither macaroon appears in process arguments.
        cmd = (
            "curl -sS --max-time 30 --cacert /secrets/lnd-cert "
            "-H @<(printf 'Grpc-Metadata-macaroon: %s\\n' "
            f'"$(xxd -ps -c 99999 {shlex.quote(macaroon)})") '
            f"-X {method} --data-binary @- "
            f"https://{ip('lnd')}:8080{path}"
        )
        return json.loads(succeed(
            f"{input_cmd} | runuser -u {shlex.quote(user)} -- bash -c {shlex.quote(cmd)}"
        ))

    # Check the policy RPC grants without requiring open channels. The admin
    # authenticates this check; the charge-lnd macaroon is the one being checked.
    lnd = test_data["lnd-macaroons"]
    for rpc in [
        "/lnrpc.Lightning/UpdateChannelPolicy",
        "/routerrpc.Router/UpdateChanStatus",
    ]:
        response = request(
            "POST", "/v1/macaroon/checkpermissions",
            user=lnd["user"], macaroon=f"{lnd['networkDir']}/admin.macaroon",
            input_cmd=(
                "runuser -u charge-lnd -- base64 -w0 /run/lnd/charge-lnd.macaroon | "
                f"jq -Rs --arg rpc {shlex.quote(rpc)} "
                "'{macaroon: ., fullMethod: $rpc, check_default_perms_from_full_method: true}'"
            ),
        )
        assert response.get("valid") is True, (rpc, response)

    # These requests must fail authorization, rather than just fail because the
    # wallet is empty, a payment is invalid, or a channel does not exist.
    for method, path in [
        ("POST", "/v2/router/send"),
        ("POST", "/v2/router/route/send"),
        ("DELETE", f"/v1/channels/{'00' * 32}/0"),
        ("DELETE", f"/v1/channels/abandon/{'00' * 32}/0"),
    ]:
        response = request(method, path)
        # Streaming RPCs wrap their errors in an extra object.
        error = response.get("error", response)
        assert error["message"] == "permission denied", (path, response)


@test("btcpayserver")
def test_btcpayserver():
    assert_running("nbxplorer")
    machine.wait_until_succeeds(log_has_string("nbxplorer", "BTC: RPC connection successful"))
    wait_for_open_port(ip("nbxplorer"), 24444)
    # Regression guard: NBXplorer's .NET host takes its content root from the
    # working directory and (by default) watches it recursively. With no
    # WorkingDirectory that was `/`, i.e. an inotify watch per directory of the
    # whole root filesystem (the Nix store included), which exhausted the
    # per-user watch limit on a production node in days. The content root must
    # be the immutable app dir (a writable one would honor a planted
    # appsettings.json), and with reload-on-change off nothing is watched.
    nbx_pid = succeed("systemctl show -p MainPID --value nbxplorer").strip()
    assert_matches(f"readlink /proc/{nbx_pid}/cwd", r"^/nix/store/[^/]+-nbxplorer-[^/]+/lib/nbxplorer$")
    nbx_watches = int(succeed(f"cat /proc/{nbx_pid}/fdinfo/* 2>/dev/null | grep -c '^inotify wd:' || true").strip() or 0)
    assert nbx_watches < 100, f"nbxplorer holds {nbx_watches} inotify watches"

    assert_running("btcpayserver")
    machine.wait_until_succeeds(log_has_string("btcpayserver", "Now listening on"))
    wait_for_open_port(ip("btcpayserver"), 23000)
    # test lnd custom macaroon
    info = succeed_json(
        "runuser -u btcpayserver -- curl -fsS --cacert /secrets/lnd-cert "
        '--header "Grpc-Metadata-macaroon: $(xxd -ps -u -c 1000 /run/lnd/btcpayserver.macaroon)" '
        f"-X GET https://{ip('lnd')}:8080/v1/getinfo"
    )
    assert info["version"], info
    # Test web server response
    assert_matches(f"curl -fsS -L {ip('btcpayserver')}:23000", "Welcome to BTCPay Server")


@test("rtl")
def test_rtl():
    assert_running("rtl")
    machine.wait_until_succeeds(
        log_has_string("rtl", "Server is up and running")
    )


@test("mempool")
def test_mempool():
    assert_running("mempool")
    assert_running("nginx")
    machine.wait_until_succeeds(
        log_has_string("mempool", "Mempool Server is running on port 8999")
    )
    # config.json holds the public RPC password
    conf = "/var/cache/mempool/config.json"
    assert_file_metadata(conf, owner="mempool", mode="600")
    # A file with laxer permissions (created by earlier versions) is replaced
    succeed(f"chmod 644 {conf} && systemctl restart mempool")
    assert_file_metadata(conf, owner="mempool", mode="600")
    machine.wait_until_succeeds(
        current_run_log_has_string("mempool", "Mempool Server is running on port 8999")
    )
    assert_matches(f"curl -L {ip('nginx')}:60845", "mempool - Bitcoin Explorer")
    # Check the backend listener in its own namespace when isolation is enabled.
    netns = "ip netns exec nb-mempool " if "netns-isolation" in enabled_tests else ""
    assert_full_match(
        f"{netns}ss -ltnH 'sport = :8999' | awk '{{print $4}}'",
        re.escape(f"{ip('mempool')}:8999\n"),
    )
    # MariaDB stays in the host namespace, including with netns isolation.
    assert_full_match("ss -ltnH 'sport = :3306' | awk '{print $4}'", r"127\.0\.0\.1:3306\n")


@test("nodeinfo")
def test_nodeinfo():
    status, _ = machine.execute("systemctl is-enabled --quiet onion-addresses 2> /dev/null")
    if status == 0:
        machine.wait_for_unit("onion-addresses")
    info = succeed_json("runuser -u operator -- nodeinfo")
    assert info["bitcoind"]["local_address"]


@test("secure-node")
def test_secure_node():
    assert_running("onion-addresses")
