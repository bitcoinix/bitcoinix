def check_bitcoin_cli_files():
    """bitcoin-cli reads the config in the Nix store, not the copy in the data dir.
    Root runs it as the bitcoin user, which owns the dirs of both files."""
    conf = "/var/lib/bitcoind/bitcoin.conf"
    cookie = "/run/bitcoind/.cookie"
    canary = "/run/bitcoin-cli-test-canary"
    capture = "/tmp/bitcoin-cli-test-capture"
    listener = "bitcoin-cli-test-listener"
    port = 18999
    chain = test_data["bitcoind-rest"]["chain"]
    planted = "".join([
        f"{chain}=1\n" if chain != "main" else "",
        f"[{chain}]\nrpcconnect=127.0.0.1\nrpcport={port}\nrpccookiefile={canary}\n",
    ])
    # Nothing else may listen there, or the check below would pass without the listener
    machine.fail(f"ss -Htln 'sport = :{port}' | grep -q .")
    succeed(
        f"install -m 600 <(echo bitcoin-cli-test:canary) {canary}",
        f"install -d -o operator -m 700 {capture}",
        f"runuser -u bitcoin -- mv -T {conf} {conf}.orig",
        f"printf %s {shlex.quote(planted)} | runuser -u bitcoin -- tee {conf} >/dev/null",
        # Record the start of each request to the address in the planted config
        f"systemd-run --unit={listener} --uid=operator"
        f" $(command -v systemd-socket-activate) --listen=127.0.0.1:{port} --accept --inetd"
        f" $(command -v dd) of={capture}/request bs=4096 count=1 status=none",
    )
    # Don't connect to check the port, which would record a request
    machine.wait_until_succeeds(f"ss -Htln 'sport = :{port}' | grep -q .")
    statuses = [machine.execute(f"{user} bitcoin-cli getnetworkinfo")[0]
                for user in ("", "runuser -u operator --")]
    captured = succeed(f"ls -A {capture}; cat {capture}/* 2>/dev/null || true")
    assert captured == "", f"bitcoin-cli used the config in the data dir:\n{captured}"
    assert statuses == [0, 0], statuses
    succeed(f"systemctl stop {listener}", f"runuser -u bitcoin -- mv -T {conf}.orig {conf}")

    # A cookie that links to a file of root
    succeed(f"runuser -u bitcoin -- sh -c 'mv -T {cookie} {cookie}.orig && ln -s {canary} {cookie}'")
    status, output = machine.execute("bitcoin-cli getnetworkinfo 2>&1")
    succeed(f"runuser -u bitcoin -- mv -T {cookie}.orig {cookie}", f"rm -r {canary} {capture}")
    assert status != 0 and "Failed to read cookie file" in output, output


@test("bitcoind")
def test_bitcoind():
    assert_running("bitcoind")
    machine.wait_until_succeeds("bitcoin-cli getnetworkinfo")
    info = succeed_json("runuser -u operator -- bitcoin-cli getnetworkinfo")
    assert isinstance(info["version"], int) and info["version"] > 0, info
    network = test_data["bitcoinNetwork"]
    genesis = {
        "mainnet": "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
        "regtest": "0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206",
        "signet": "00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6",
        "testnet4": "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043",
    }[network]
    assert succeed("bitcoin-cli getblockhash 0").strip() == genesis

    # The cookie lives in a runtime directory that only the bitcoin user can write
    cookie = "/run/bitcoind/.cookie"
    assert_file_metadata("/run/bitcoind", owner="bitcoin", group="bitcoin", mode="750")
    assert_file_metadata(cookie, mode="640")
    # Group members can read the cookie
    succeed(f"runuser -u operator -- cat {cookie} >/dev/null")
    # Group members cannot replace it
    machine.fail(f"runuser -u operator -- mv {cookie} {cookie}.moved")
    check_bitcoin_cli_files()
    # No cookie is left in the data directory
    assert not succeed("find /var/lib/bitcoind -name .cookie").strip()

    # RPC access for user 'public' should be restricted
    machine.fail(
        "bitcoin-cli -rpcuser=public -rpcpassword=$(cat /secrets/bitcoin-rpcpassword-public) stop"
    )
    machine.wait_until_succeeds(
        log_has_string("bitcoind", "RPC User public not allowed to call method stop")
    )

    # Group members read bitcoin.conf, as bitcoin-cli above shows, but they don't
    # write the data directory
    assert_file_metadata("/var/lib/bitcoind", owner="bitcoin", group="bitcoin", mode="750")
    machine.fail("runuser -u operator -- touch /var/lib/bitcoind/group-write-probe")


@test("bitcoind-group-read")
def test_bitcoind_group_read():
    data = test_data["bitcoind-group-read"]
    network_dir = data["networkDir"]
    blocks = f"{network_dir}/blocks"

    def block_files():
        return set(succeed(f"find {blocks} -type f -printf '%P\\n'").split())

    # Logged by the unit that sets up the group's access before each start of bitcoind
    warning = "let the group read all files"

    def assert_group_reads_blocks():
        unreadable = succeed(f"runuser -u operator -- find {blocks} ! -readable")
        assert unreadable == "", f"Not readable by group members:\n{unreadable}"

    machine.wait_until_succeeds("bitcoin-cli getnetworkinfo")
    # On its first start, bitcoind created all these files after the setup, so
    # only the ACL lets the group read them
    assert_group_reads_blocks()
    # After a restart, the setup covers the existing files. bitcoind creates
    # new ones after it, like a new block index log on each start.
    before = block_files()
    setup_run = succeed("systemctl show -P InvocationID bitcoind-group-read")
    succeed("systemctl restart bitcoind")
    machine.wait_until_succeeds("bitcoin-cli getnetworkinfo")
    # The setup runs again before each start of bitcoind
    assert succeed("systemctl show -P InvocationID bitcoind-group-read") != setup_run
    created = block_files() - before
    assert created, f"bitcoind created no file in {blocks}"
    assert_group_reads_blocks()
    machine.fail(current_run_log_has_string("bitcoind-group-read", warning))
    # Also when systemd restarts bitcoind after a crash
    setup_run = succeed("systemctl show -P InvocationID bitcoind-group-read")
    bitcoind_run = succeed("systemctl show -P InvocationID bitcoind").strip()
    succeed("systemctl kill -s KILL bitcoind")
    machine.wait_until_succeeds(
        f"systemctl show -P InvocationID bitcoind | grep -Ex '[0-9a-f]{{32}}' | grep -vx {bitcoind_run}"
    )
    machine.wait_until_succeeds("bitcoin-cli getnetworkinfo")
    assert succeed("systemctl show -P InvocationID bitcoind-group-read") != setup_run
    succeed("systemctl reset-failed bitcoind")
    # The group gets no access beyond the blocks dir
    machine.fail(f"runuser -u operator -- ls {network_dir}/chainstate")
    mainnet = data["network"] == "mainnet"
    if not mainnet:
        # Core creates `wallets` only in a network dir that it creates itself,
        # and the setup creates the regtest dir first
        succeed(f"test -d {network_dir}/wallets")

    # Older versions let group members replace an entry in the data dir with a
    # symlink: `blocks` on mainnet, `regtest` on regtest. The setup must
    # not follow it, and not a symlink at the blocks dir either. Each symlink here
    # points to the real dir, without group access.
    for planted in [blocks] if mainnet else [network_dir, blocks]:
        target = f"{planted}.real"
        succeed(
            "systemctl stop bitcoind",
            f"mv {planted} {target}",
            f"chmod -R g-rwx {target}",
            f"setfacl -R -b -k {target}",
            f"ln -s {target} {planted}",
            # Restarting this often hits the unit's start limit
            "systemctl reset-failed bitcoind",
            "systemctl start bitcoind",
        )
        assert_full_match(f"find {target} -perm /g=rwx", "")
        assert_full_match(f"getfacl -R -s -p {target}", "")
        machine.wait_until_succeeds(current_run_log_has_string("bitcoind-group-read", warning))
        succeed(
            "systemctl stop bitcoind",
            f"rm {planted}",
            f"mv {target} {planted}",
            "systemctl reset-failed bitcoind",
            "systemctl start bitcoind",
        )
    machine.wait_until_succeeds("bitcoin-cli getnetworkinfo")
    assert_group_reads_blocks()

    # An ACL that the admin set before, for example for a backup tool. The owning
    # group has no rights, and the mask limits a named group's write right. Below
    # the block index dir and on the network dir, the masks hide all rights of the
    # named groups. The setup must let the owning group read the blocks dir without
    # changing the effective rights of the named groups, also not on the files that
    # bitcoind creates later.
    def named_rights():
        """The effective rights of each named ACL entry, by path and entry"""
        acls = succeed(f"getfacl -p {network_dir}", f"getfacl -R -p {blocks}")
        rights = {}
        path = ""
        for line in acls.splitlines():
            if line.startswith("# file: "):
                path = line.removeprefix("# file: ")
            elif m := re.fullmatch(r"((?:default:)?(?:user|group):[^:]+):(\S+)(?:\s+#effective:(\S+))?", line):
                rights[(path, m[1])] = m[3] or m[2]
        return rights

    succeed(
        "systemctl stop bitcoind",
        f"setfacl -R -m g::-,g:blockbackup:rX,g:blockwriter:rwX,m::rX {blocks}",
        f"setfacl -R -d -m u::rwx,g::-,g:blockbackup:rx,g:blockwriter:rwx,m::rx,o::- {blocks}",
        f"setfacl -R -m m::- {blocks}/index",
        f"setfacl -m d:m::- {blocks}/index",
        f"setfacl -m g::-,g:blockwriter:rwx,m::- {network_dir}",
    )
    before = named_rights()
    paths = {path for path, _ in before}
    succeed("systemctl reset-failed bitcoind", "systemctl start bitcoind")
    machine.wait_until_succeeds("bitcoin-cli getnetworkinfo")
    assert_group_reads_blocks()
    machine.fail(current_run_log_has_string("bitcoind-group-read", warning))
    after = named_rights()
    # bitcoind deletes some old block index files when it starts
    kept = paths & {path for path, _ in after}
    assert {network_dir, blocks} <= kept, kept
    changed = {entry: (rights, after.get(entry)) for entry, rights in before.items()
               if entry[0] in kept and after.get(entry) != rights}
    assert not changed, f"Named entries with changed effective rights: {changed}"
    new_writer = {path: rights for (path, entry), rights in after.items()
                  if path not in paths and entry == "group:blockwriter"}
    assert new_writer, "No file that bitcoind created has the default ACL's entry for blockwriter"
    assert not any("w" in rights for rights in new_writer.values()), new_writer

    # The setup gives rights to the owning group of each entry, so it must leave
    # an entry of another group alone, warn, and still cover the other entries
    other = f"{blocks}/other-group"
    succeed(
        f"install -o bitcoin -g blockbackup -m 600 /dev/null {other}",
        f"install -o bitcoin -g bitcoin -m 600 /dev/null {blocks}/zz-own-group",
        "systemctl start bitcoind-group-read",
    )
    machine.wait_until_succeeds(current_run_log_has_string("bitcoind-group-read", warning))
    assert_full_match(f"stat -c %a {other}", "600\n")
    assert_full_match(f"runuser -u operator -- find {blocks} ! -readable", f"{other}\n")
    succeed(f"rm {other} {blocks}/zz-own-group")


@test("i2pd")
def test_i2pd():
    assert_running("i2pd")
    sam = test_data["i2pd"]
    pid = machine.succeed("systemctl show -P MainPID i2pd").strip()
    assert int(pid) > 0
    listeners = machine.succeed("ss -Htlnp")
    ports = sorted({
        line.split()[3].rsplit(":", 1)[1]
        for line in listeners.splitlines() if f"pid={pid}," in line
    })
    assert ports == [str(sam["port"])], f"i2pd listens on {ports} instead of only SAM"
    namespace = "ip netns exec nb-bitcoind " if sam["netns"] else ""
    # Verify the SAM protocol from Bitcoin's network namespace, including the
    # bridge firewall, rather than only connecting from the host namespace.
    machine.wait_until_succeeds(
        "printf 'HELLO VERSION MIN=3.1 MAX=3.1\\n' | "
        f"{namespace}nc -w 3 {shlex.quote(sam['address'])} {sam['port']} | "
        "grep -F 'HELLO REPLY RESULT=OK VERSION=3.1'"
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
    network = test_data["bitcoinNetwork"]
    assert info["network"] == ("bitcoin" if network == "mainnet" else network), info

    # Group members, like the operator and BTCPay Server, use the RPC socket.
    # They must not write the data dir, which holds the config that lightningd
    # loads and the network dir with hsm_secret.
    data = test_data["clightning"]
    data_dir, user, group = data["dataDir"], data["user"], data["group"]
    assert_file_metadata(data_dir, owner=user, group=group, mode="750")
    # The RPC socket is the only entry that the group or others can write
    rpc_socket = f"{data['networkDir']}/lightning-rpc"
    assert_full_match(f"find {shlex.quote(data_dir)} -perm /022", re.escape(f"{rpc_socket}\n"))
    assert_full_match(f"find {shlex.quote(data_dir)} ! -user {shlex.quote(user)}", "")
    members = succeed(f"getent group {shlex.quote(group)}").strip().split(":")[3]
    probe = shlex.quote(f"{data_dir}/group-write-probe")
    for member in filter(None, members.split(",")):
        as_member = f"runuser -u {shlex.quote(member)} --"
        succeed(f"{as_member} lightning-cli getinfo >/dev/null")
        machine.fail(f"{as_member} touch {probe}")
    check_lightning_cli_config(data_dir, user)

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

        # Check the Rust currencyrate RPCs without querying public price sources.
        if "cln-currencyrate" in active:
            methods = {method["command"].split()[0]
                       for method in succeed_json("lightning-cli -J help")["help"]}
            assert {"currencyrate", "currencyconvert", "listcurrencyrates"} <= methods
            assert "currencyrates" not in methods

        if "feeadjuster" in active:
            # This is a one-shot service, so this command only succeeds if the service succeeds
            succeed("systemctl start clightning-feeadjuster")

    if replication := test_data["clightning-replication"]:
        replica_db = shlex.quote(replication["wallet"].removeprefix("sqlite3://").split(":", 1)[1])
        succeed(f"runuser -u clightning -- test -r {replica_db}")
        # No other user should be able to read the unencrypted files
        machine.fail(f"runuser -u bitcoin -- test -r {replica_db}")
        if directory := replication["encryptedLocalDir"]:
            succeed(f"test -f {shlex.quote(directory + '/lightningd-db/gocryptfs.conf')}")


def check_lightning_cli_config(data_dir, user):
    """Root runs lightning-cli as the clightning user, which owns the config that
    lightning-cli reads. So an include in that config can't open a file of root."""
    config = f"{data_dir}/config"
    canary = "/run/lightning-cli-test-canary"
    succeed(
        f"install -m 600 <(echo '# lightning-cli-test-canary') {canary}",
        f"runuser -u {user} -- sh -c 'cp -p {config} {config}.orig && echo include {canary} >> {config}'",
    )
    status, output = machine.execute("lightning-cli getinfo 2>&1")
    succeed(f"runuser -u {user} -- mv -T {config}.orig {config}", f"rm {canary}")
    assert status != 0 and f"Opening and reading {canary}: Permission denied" in output, output


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
    assert_full_match("</secrets/lnd-cert openssl x509 -noout -subject", "subject=CN=localhost\n")

    # lnd announces its public onion address with the port that Tor forwards
    onion = test_data["lnd-public-onion"]
    if onion:
        address = succeed(f"cat {onion['addressFile']}").strip()
        uri = f"{info['identity_pubkey']}@{address}:{onion['port']}"
        assert uri in info["uris"], info["uris"]

        # Without the address, or with an empty one, preStart fails before it
        # writes lnd.conf. Run it directly: a failed lnd unit would fail later
        # checks that lnd never failed.
        address_file, conf = onion["addressFile"], onion["conf"]
        pre_start = f"runuser -u {onion['user']} -- {onion['preStart']} 2>&1"
        conf_state = f"stat -c '%i %Y' {conf} && sha256sum {conf}"
        before = succeed(conf_state)
        succeed(f"mv -T {address_file} {address_file}.orig")
        try:
            missing = machine.execute(pre_start)
            succeed(f"install -m 400 -o {onion['user']} /dev/null {address_file}")
            empty = machine.execute(pre_start)
        finally:
            succeed(f"mv -T {address_file}.orig {address_file}")
        assert missing[0] != 0 and f"{address_file}: No such file or directory" in missing[1], missing
        assert empty[0] != 0 and "getPublicAddressCmd printed no address" in empty[1], empty
        assert succeed(conf_state) == before, "preStart replaced lnd.conf"

    # Go 1.24 listens with Multipath TCP by default. The lnd unit turns that
    # off, so no lnd socket may show up as an MPTCP listener. Look in lnd's
    # namespace, and check that ss sees lnd there at all, so the test can't
    # pass by looking in the wrong place.
    netns = "ip netns exec nb-lnd " if "netns-isolation" in enabled_tests else ""
    assert_str_matches(succeed(f"{netns}ss -ltnp"), '"lnd"')
    mptcp_listeners = succeed(f"{netns}ss -Mlnp")
    assert "lnd" not in mptcp_listeners, mptcp_listeners


@test("charge-lnd")
def test_charge_lnd():
    # charge-lnd is a oneshot service that is started by a timer under regular operation
    succeed("systemctl start charge-lnd")
    assert_no_failure("charge-lnd")
    # Explicit credential paths must work without a synthetic mainnet datadir.
    succeed("test ! -e /var/lib/charge-lnd/lnddir-proxy")

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
    policy_rpcs = [
        "/lnrpc.Lightning/UpdateChannelPolicy",
        "/routerrpc.Router/UpdateChanStatus",
    ]
    for rpc, response in zip(
        policy_rpcs,
        check_lnd_macaroon_permissions(
            lnd, "/run/lnd/charge-lnd.macaroon", policy_rpcs, macaroon_user="charge-lnd"
        ),
    ):
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
    # btcpayserver is in NBXplorer's group to read the API cookie. That group
    # must not give it NBXplorer's bitcoind RPC password.
    rpc_password = "/secrets/bitcoin-rpcpassword-btcpayserver"
    assert_file_metadata(rpc_password, owner="nbxplorer", mode="400")
    machine.fail(f"runuser -u btcpayserver -- cat {rpc_password}")
    conf = succeed("systemctl show -P ExecStart btcpayserver")
    config_file = re.search(r"--conf=(/nix/store/[^ ]+)", conf)
    assert config_file, conf
    cookie = succeed(f"sed -n 's/^btcexplorercookiefile=//p' {config_file[1]}").strip()
    succeed(f"runuser -u btcpayserver -- cat {shlex.quote(cookie)} >/dev/null")
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
    if test_data["btcpayserver"]["lightningBackend"] == "lnd":
        # test lnd custom macaroon
        info = succeed_json(
            "runuser -u btcpayserver -- curl -fsS --cacert /secrets/lnd-cert "
            '--header "Grpc-Metadata-macaroon: $(xxd -ps -u -c 1000 /run/lnd/btcpayserver.macaroon)" '
            f"-X GET https://{ip('lnd')}:8080/v1/getinfo"
        )
        assert info["version"], info
    # Test web server response
    assert_matches(f"curl -fsS -L {ip('btcpayserver')}:23000", "Welcome to BTCPay Server")

    # The admin exists before btcpayserver opens its port, so an anonymous
    # request can't create the first admin. Registration is closed.
    assert_matches("systemctl show -P PrivateNetwork btcpayserver-admin", "yes")
    api = f"http://{ip('btcpayserver')}:23000/api/v1"
    me = succeed_json(f'curl -fsS -u "{btcpayserver_admin()}" {api}/users/me')
    assert "ServerAdmin" in me["roles"], me
    for is_admin in ["true", "false"]:
        assert_full_match(
            f"curl -sS -o /dev/null -w '%{{http_code}}' -X POST {api}/users "
            "-H 'Content-Type: application/json' "
            f"""-d '{{"email": "user@localhost", "password": "user-password", "isAdministrator": {is_admin}}}'""",
            "401",
        )
    assert_full_match(
        f"curl -sS -o /dev/null -w '%{{http_code}}' {ip('btcpayserver')}:23000/register", "302"
    )


def rtl_url(address, port):
    host = f"[{address}]" if ":" in address else address
    return f"http://{host}:{port}/rtl"


def assert_rtl_ui(url):
    """RTL's login page, a login, and an API call that needs the login"""
    jar = "/tmp/rtl-cookies"
    _, token = rtl_login(url, jar)
    rtl_config = f"curl -sS -b {jar} -o /dev/null -w '%{{http_code}}' {url}/api/conf/config/rtl"
    assert_full_match(rtl_config, "401")
    assert_full_match(f"{rtl_config} -H 'Authorization: Bearer {token}'", "200")
    succeed(f"rm {jar}")


@test("rtl")
def test_rtl():
    assert_running("rtl")
    machine.wait_until_succeeds(
        log_has_string("rtl", "Server is up and running")
    )

    def restart_rtl():
        succeed("systemctl restart rtl")
        assert_running("rtl")
        machine.wait_until_succeeds(
            current_run_log_has_string("rtl", "Server is up and running")
        )

    data = test_data["rtl"]
    address, port = data["address"], data["port"]
    url = rtl_url(address, port)
    assert_rtl_ui(url)
    if onion := data["onionTarget"]:
        assert_rtl_ui(rtl_url(onion["addr"], onion["port"]))

    # While RTL is stopped, for example during a backend's maintenance, no other
    # local user can take its address and port and collect the password
    succeed("systemctl stop rtl")

    def assert_port_held():
        status, out = machine.execute(f"runuser -u nobody -- timeout 3 nc -l {address} {port} 2>&1")
        assert re.search("Address already in use|Cannot assign requested address", out), \
            f"An unprivileged user took RTL's port (status {status}): {out!r}"

    assert_port_held()
    # A connection gets no answer
    machine.fail(f"curl -sS --max-time 10 {url}/")
    if data["proxy"]:
        # Connections that the proxy can't forward stop neither it nor the socket
        proxy_pid = "systemctl show -P MainPID rtl-proxy"
        pid = succeed(proxy_pid).strip()
        assert pid != "0", "rtl-proxy isn't running"
        succeed(f"for i in $(seq 20); do curl -sS --max-time 2 {url}/ || true; done")
        assert succeed(proxy_pid).strip() == pid, "rtl-proxy restarted"
        # A crashing proxy doesn't make systemd close the socket
        for _ in range(6):
            succeed("systemctl kill -s KILL rtl-proxy")
            machine.execute(f"curl -sS --max-time 2 {url}/")
            # The next kill must hit a new proxy, not the restart delay
            machine.wait_until_succeeds(f"pid=$({proxy_pid}); [[ $pid != 0 && $pid != {pid} ]]", timeout=60)
            pid = succeed(proxy_pid).strip()
        # systemd holds the port
        assert_matches(f"ss -Htlnp 'sport = :{port}'", r'\("systemd",pid=1,')
        assert_port_held()
    restart_rtl()
    assert_rtl_ui(url)

    # The 2FA secret set up in the UI survives a restart
    conf = f"{test_data['rtl-credentials']['dataDir']}/RTL-Config.json"

    def restart_with_secret_2fa(secret):
        # `cat` writes in place, which keeps the file's owner and mode
        succeed(
            f"tmp=$(mktemp) && jq --arg s '{secret}' '.secret2FA = $s' {conf} > $tmp"
            f" && cat $tmp > {conf} && rm $tmp"
        )
        restart_rtl()

    # RTL reports `enable2FA` to clients before login
    enable_2fa = f"curl -fsS {url}/api/conf | jq .enable2FA"

    restart_with_secret_2fa("JBSWY3DPEHPK3PXP")
    assert_full_match(f"jq -r .secret2FA {conf}", "JBSWY3DPEHPK3PXP\n")
    assert_full_match(enable_2fa, "true\n")
    # The config holds the RTL password and the 2FA secret
    assert_file_metadata(conf, owner=test_data["rtl-credentials"]["user"], mode="600")
    # An empty secret is not carried over. This restores the original config.
    restart_with_secret_2fa("")
    succeed(f"jq -e 'has(\"secret2FA\") | not' {conf}")
    assert_full_match(enable_2fa, "false\n")
    # A file with two JSON values, which RTL can't parse, isn't carried over
    succeed(f"""echo '{{"secret2FA": "JBSWY3DPEHPK3PXP"}} {{}}' > {conf}""")
    restart_rtl()
    succeed(current_run_log_has_string("rtl", "single JSON object"))
    succeed(f"jq -e 'has(\"secret2FA\") | not' {conf}")


@test("mempool")
def test_mempool():
    assert_running("mempool")
    assert_running("nginx")
    machine.wait_until_succeeds(
        log_has_string("mempool", "Mempool Server is running on port 8999")
    )
    # config.json holds mempool's RPC password
    conf = "/var/cache/mempool/config.json"
    assert_file_metadata(conf, owner="mempool", mode="600")
    # A file with laxer permissions (created by earlier versions) is replaced
    succeed(f"chmod 644 {conf} && systemctl restart mempool")
    assert_file_metadata(conf, owner="mempool", mode="600")
    machine.wait_until_succeeds(
        current_run_log_has_string("mempool", "Mempool Server is running on port 8999")
    )
    network = test_data["bitcoinNetwork"]
    assert succeed_json(f"cat {conf}")["MEMPOOL"]["NETWORK"] == network
    frontend_config = succeed(f"curl -fsSL {ip('nginx')}:60845/resources/config.js")
    if network == "mainnet":
        # The packaged frontend uses compiled defaults without runtime overrides.
        for setting in ("ROOT_NETWORK", "MAINNET_ENABLED", "REGTEST_ENABLED", "SIGNET_ENABLED", "TESTNET4_ENABLED"):
            assert f"window.__env.{setting} =" not in frontend_config
    else:
        assert f"window.__env.ROOT_NETWORK = '{network}';" in frontend_config
        assert "window.__env.MAINNET_ENABLED = false;" in frontend_config
        assert f"window.__env.{network.upper()}_ENABLED = true;" in frontend_config
    assert_matches(f"curl -L {ip('nginx')}:60845", "mempool - Bitcoin Explorer")
    # No cache validators, and no 304 for the store's 1970 timestamp
    headers = succeed(f"curl -sI -H 'If-Modified-Since: Thu, 01 Jan 1970 00:00:01 GMT' {ip('nginx')}:60845")
    assert headers.startswith("HTTP/1.1 200"), headers
    assert not re.search(r"(?im)^(etag|last-modified):", headers), headers
    info = succeed_json(f"curl -s {ip('nginx')}:60845/api/v1/backend-info")
    assert info["hostname"] == info["osVersion"] == "", info
    # Malformed JSON gets the production error page, without a stack trace
    assert_matches(
        f"curl -s -H 'Content-Type: application/json' -d '{{' {ip('nginx')}:60845/api/v1/prevouts",
        "<pre>Bad Request</pre>",
    )
    # Check the backend listener in its own namespace when isolation is enabled.
    netns = "ip netns exec nb-mempool " if "netns-isolation" in enabled_tests else ""
    assert_full_match(
        f"{netns}ss -ltnH 'sport = :8999' | awk '{{print $4}}'",
        re.escape(f"{ip('mempool')}:8999\n"),
    )
    # MariaDB stays in the host namespace, including with netns isolation.
    assert_full_match("ss -ltnH 'sport = :3306' | awk '{print $4}'", r"127\.0\.0\.1:3306\n")


@test("unbeholden-wallet")
def test_unbeholden_wallet():
    assert_running("unbeholden-wallet")
    url = f"{ip('unbeholden-wallet')}:60846"
    wait_for_open_port(ip("unbeholden-wallet"), 60846)
    assert_matches(f"curl {url}", "<title>Unbeholden Wallet</title>")
    status = f"curl -s -o /dev/null -w '%{{http_code}}' {url}"
    assert_full_match(f"{status} -H 'Host: evil.example'", "403")
    for host in test_data["unbeholden-wallet"]["allowedHosts"]:
        assert_full_match(f"{status} -H 'Host: {host}'", "200")
    probe = test_data.get("unbeholden-wallet-clients")
    if probe:
        allowed, denied = probe["allowed"], probe["denied"]
        succeed(f"ip addr add {allowed}/32 dev lo", f"ip addr add {denied}/32 dev lo")
        remote = f"curl -s -o /dev/null -w '%{{http_code}}' -m 5 {allowed}:60846 --interface"
        assert_full_match(f"{remote} {allowed}", "200")
        machine.fail(f"{remote} {denied}")
    # Mainnet fixtures never sync, so their Electrum backend may not listen.
    if "regtest" not in enabled_tests:
        return
    backend = test_data["unbeholden-wallet"]["electrumServer"]
    request = '{"jsonrpc":"2.0","id":1,"method":"server.version","params":["test","1.4"]}'
    machine.wait_until_succeeds(
        f"echo '{request}' | websocat -n1 ws://{url}/electrum | grep -qi {backend}"
    )


@test("nodeinfo")
def test_nodeinfo():
    status, _ = machine.execute("systemctl is-enabled --quiet onion-addresses 2> /dev/null")
    if status == 0:
        machine.wait_for_unit("onion-addresses")
    info = succeed_json("runuser -u operator -- nodeinfo")
    # Fixed in test/tests.nix
    revision = "0123456789abcdef0123456789abcdef01234567"
    assert info["bitcoinix"]["revision"] == revision
    assert info["bitcoind"]["local_address"]
    for name, version in test_data["nodeinfo-versions"].items():
        # A stopped service has no version
        if isinstance(info[name], dict):
            assert info[name].get("version") == version, f"{name}: expected version {version!r}: {info[name]}"
    assert_full_match("runuser -u operator -- nodeinfo --version", f'"{revision}"\n')
    assert list(succeed_json("runuser -u operator -- nodeinfo bitcoind")) == ["bitcoind"]
    machine.fail("runuser -u operator -- nodeinfo no-such-service")
    if status == 0:
        check_nodeinfo_onion_files(info)


def check_nodeinfo_onion_files(info):
    """Root runs nodeinfo too. It reads the onion addresses in the operator's dir,
    but only from regular files that the operator owns."""
    # (service, output field, address file)
    fixtures = [(name, "onion_address", name) for name in info]
    fixtures.append(("lnd", "onion_rest_address", "lnd-rest"))
    name, field, file_name = next(
        (fixture for fixture in fixtures
         if isinstance(info.get(fixture[0]), dict) and info[fixture[0]].get(fixture[1])),
        (None, None, None))
    assert name, f"nodeinfo shows no onion address: {info}"
    file = f"/var/lib/onion-addresses/operator/{file_name}"
    canary = "/run/nodeinfo-test-canary"
    assert succeed_json(f"nodeinfo {name}")[name] == info[name]
    succeed(f"install -m 600 <(echo {'c' * 56}.onion) {canary}",
            f"runuser -u operator -- mv -T {file} {file}.orig")
    replacements = {
        "symlink": f"runuser -u operator -- ln -s {canary} {file}",
        # Like a hard link to a file of root
        "file of root": f"cp {canary} {file}",
        "FIFO": f"runuser -u operator -- mkfifo {file}",
    }
    for kind, plant in replacements.items():
        with machine.nested(f"onion address file is a {kind}"):
            succeed(plant)
            # The timeout stops a read that blocks on the FIFO
            status, output = machine.execute(f"timeout 30 nodeinfo {name}")
            succeed(f"rm {file}")
            assert status == 0 and json.loads(output)[name][field] is None, output
    succeed(f"runuser -u operator -- mv -T {file}.orig {file}", f"rm {canary}")


@test("secure-node")
def test_secure_node():
    assert_running("onion-addresses")


@test("unbeholden-lnurl")
def test_unbeholden_lnurl():
    data = test_data["unbeholden-lnurl"]
    assert_running("unbeholden-lnurl")
    url = f"http://{ip('unbeholden-lnurl')}:{data['port']}"
    wait_for_open_port(ip("unbeholden-lnurl"), data["port"])
    assert_full_match(f"curl -fsS {url}/health", "ok")
    address = f"{url}/.well-known/lnurlp/test"
    discovery = succeed_json(f"curl -fsS {address}")
    assert discovery["tag"] == "payRequest", discovery
    assert discovery["minSendable"] == 1000, discovery
    assert discovery["maxSendable"] == 1000000, discovery
    assert urlparse(discovery["callback"]).path == "/.well-known/lnurlp/test/invoice"
    assert ["text/plain", "Bitcoinix test"] in json.loads(discovery["metadata"])
    assert_full_match(
        f"curl -sS -o /dev/null -w '%{{http_code}}' {url}/.well-known/lnurlp/unknown", "404"
    )
    invalid = succeed_json(f"curl -fsS '{address}/invoice?amount=999'")
    assert invalid["status"] == "ERROR", invalid
    command = f"curl -fsS '{address}/invoice?amount=1000'"
    invoice = json.loads(machine.wait_until_succeeds(
        command + " | jq -e 'select(.pr | startswith(\"lnbcrt\"))'"
    ))
    assert invoice["routes"] == [], invoice
    verify_path = urlparse(invoice["verify"]).path
    verified = succeed_json(f"curl -fsS {url}{shlex.quote(verify_path)}")
    assert verified == {
        "status": "OK", "settled": False, "preimage": None, "pr": invoice["pr"]
    }, verified
    if data["backend"] == "clightning":
        rune_file = f"{data['dataDir']}/cln-rune"
        record_file = f"{data['clnDataDir']}/unbeholden-lnurl-rune"

        def runes():
            return {r["unique_id"]: r for r in succeed_json("lightning-cli showrunes")["runes"]}

        def blacklisted():
            return {id for id, r in runes().items() if r.get("blacklisted")}

        def recorded():
            rune = succeed(f"cat {record_file}").strip()
            return next(id for id, r in runes().items() if r["rune"] == rune)

        def restart_with_rune_file(content):
            succeed(
                f"runuser -u unbeholden-lnurl -- tee {rune_file} <<< {shlex.quote(content)}",
                "systemctl restart unbeholden-lnurl",
            )
            machine.wait_for_unit("unbeholden-lnurl")

        before = runes()
        rune_id = recorded()
        assert succeed(f"cat {rune_file}").strip() == before[rune_id]["rune"]
    succeed("systemctl restart unbeholden-lnurl")
    machine.wait_for_unit("unbeholden-lnurl")
    if data["backend"] == "clightning":
        assert runes().keys() == before.keys(), "A restart created another rune"
        assert recorded() == rune_id
        # A changed rune file revokes only the recorded rune. Its content is
        # never passed to lightning-cli, so a forged rune can't pick a rune to revoke.
        other = succeed_json("lightning-cli createrune restrictions='[[\"method=getinfo\"]]'")
        for content in [other["rune"], '"{\\"filter\\":{}}"']:
            revoked = blacklisted() | {rune_id}
            restart_with_rune_file(content)
            assert blacklisted() == revoked, (blacklisted(), revoked)
            assert recorded() != rune_id
            rune_id = recorded()
            assert succeed(f"cat {rune_file}").strip() == runes()[rune_id]["rune"]
        # The setup accesses the data dir only as the service user, so a
        # planted symlink can't redirect a read or write to a file of another user
        target = "/etc/unbeholden-lnurl-target"
        succeed(
            f"install -m 600 <(echo original) {target}",
            f"runuser -u unbeholden-lnurl -- ln -sfT {target} {rune_file}",
            "systemctl restart unbeholden-lnurl",
        )
        machine.wait_for_unit("unbeholden-lnurl")
        assert_full_match(f"stat -c '%U %a' {target} && cat {target}", "root 600\noriginal\n")
        assert_full_match(f"stat -c %F {rune_file}", "regular file\n")
        succeed(f"rm {target}")
        # After clightning starts on a new or restored database, the recorded
        # rune is missing, and its ID can belong to another rune. Revoke nothing.
        revoked = blacklisted()
        succeed(
            f"runuser -u clightning -- tee {record_file} <<< missing-rune",
            "systemctl reset-failed unbeholden-lnurl",
            "systemctl restart unbeholden-lnurl",
        )
        machine.wait_for_unit("unbeholden-lnurl")
        assert blacklisted() == revoked, (blacklisted(), revoked)
        assert succeed(f"cat {rune_file}").strip() == runes()[recorded()]["rune"]
    machine.wait_until_succeeds(f"curl -fsS {url}/health")
    assert succeed_json(f"curl -fsS {url}{shlex.quote(verify_path)}") == verified
