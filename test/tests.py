from collections import OrderedDict
import json
import os
import re

def succeed(*cmds):
    """Returns the concatenated output of all cmds"""
    return machine.succeed(*cmds)

def assert_matches(cmd, regexp):
    assert_str_matches(succeed(cmd), regexp)

def assert_str_matches(str, regexp):
    if not re.search(regexp, str):
        raise Exception(f"Pattern '{regexp}' not found in '{str}'")

def assert_full_match(cmd, regexp):
    out = succeed(cmd)
    if not re.fullmatch(regexp, out):
        raise Exception(f"Pattern '{regexp}' doesn't match '{out}'")

def log_has_string(unit, str):
    return f"journalctl -b --output=cat -u {unit} --grep='{str}'"

def assert_no_failure(unit):
    """Unit should not have failed since the system is running"""
    machine.fail(log_has_string(unit, "Failed with result"))

def assert_running(unit):
    with machine.nested(f"waiting for unit: {unit}"):
        machine.wait_for_unit(unit)
    assert_no_failure(unit)

def wait_for_open_port(address, port):
    def is_port_open(_):
        status, _ = machine.execute(f"nc -z {address} {port}")
        return status == 0

    with machine.nested(f"Waiting for TCP port {address}:{port}"):
        retry(is_port_open)


### Test runner

tests = OrderedDict()

def test(name):
    def x(fn):
        tests[name] = fn
    return x

# `run_tests` is already defined by the NixOS test driver
def nb_run_tests():
    enabled = enabled_tests.copy()
    to_run = []
    for test in tests:
        if test in enabled:
            enabled.remove(test)
            to_run.append(test)
    if enabled:
        raise RuntimeError(f"The following tests are enabled but not defined: {enabled}")
    machine.connect()  # Visually separate boot output from the test output
    for test in to_run:
        with machine.nested(f"test: {test}"):
            tests[test]()

def run_test(test):
    tests[test]()


### Tests
# All tests are executed in the order they are defined here

@test("security")
def _():
    assert_running("setup-secrets")
    # Unused secrets should be inaccessible
    succeed('[[ $(stat -c "%U:%G %a" /secrets/dummy) = "root:root 440" ]]')

    if "secure-node" in enabled_tests:
        machine.wait_for_unit("bitcoind")
        # `systemctl status` run by unprivileged users shouldn't leak cgroup info
        assert_matches(
            "runuser -u electrs -- systemctl status bitcoind 2>&1 >/dev/null",
            "Failed to dump process list for 'bitcoind.service', ignoring: Access denied",
        )
        # The 'operator' with group 'proc' has full access
        assert_full_match("runuser -u operator -- systemctl status bitcoind 2>&1 >/dev/null", "")

@test("bitcoind")
def _():
    assert_running("bitcoind")
    machine.wait_until_succeeds("bitcoin-cli getnetworkinfo")
    assert_matches("runuser -u operator -- bitcoin-cli getnetworkinfo | jq", '"version"')

    regtest = "regtest/" if "regtest" in enabled_tests else ""
    cookie = f"/var/lib/bitcoind/{regtest}.cookie"
    # bitcoind creates the cookie world-readable (`rpccookieperms=all` in ./tests.nix)
    assert_full_match(f"stat -c '%a' {cookie}", "640\n")
    # Group members can read the cookie
    succeed(f"runuser -u operator -- cat {cookie} >/dev/null")
    # postStart refuses to chmod a cookie that was replaced by a symlink
    post_start = succeed(
        "systemctl show -p ExecStartPost --value bitcoind | grep -o 'path=[^ ;]*' | cut -d= -f2"
    ).split()
    assert len(post_start) == 1, post_start
    target = "/var/lib/bitcoind/cookie-symlink-target"
    succeed(
        f"install -o bitcoin -g bitcoin -m 600 /dev/null {target}",
        f"mv {cookie} {cookie}.orig",
        f"ln -s {target} {cookie}",
    )
    assert_matches(
        f'! out=$(runuser -u bitcoin -- {post_start[0]} 2>&1) && echo "$out"',
        "is not a regular file",
    )
    assert_full_match(f"stat -c '%a' {target}", "600\n")
    succeed(f"rm {cookie} {target}", f"mv {cookie}.orig {cookie}")

    # RPC access for user 'public' should be restricted
    machine.fail(
        "bitcoin-cli -rpcuser=public -rpcpassword=$(cat /secrets/bitcoin-rpcpassword-public) stop"
    )
    machine.wait_until_succeeds(
        log_has_string("bitcoind", "RPC User public not allowed to call method stop")
    )

@test("electrs")
def _():
    assert_running("electrs")
    wait_for_open_port(ip("electrs"), 4224)  # prometeus metrics provider
    # Check RPC connection to bitcoind
    if not "regtest" in enabled_tests:
        machine.wait_until_succeeds(
            log_has_string("electrs", "waiting for 0 blocks to download")
        )

@test("fulcrum")
def _():
    assert_running("fulcrum")
    machine.wait_until_succeeds(log_has_string("fulcrum", "started ok"))

# Impure: Stops electrs
# Stop electrs from spamming the test log with 'waiting for 0 blocks to download' messages
@test("stop-electrs")
def _():
    succeed("systemctl stop electrs")

@test("clightning")
def _():
    assert_running("clightning")
    assert_matches("runuser -u operator -- lightning-cli getinfo | jq", '"id"')

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
def _():
    assert_running("lnd")
    assert_matches("runuser -u operator -- lncli getinfo | jq", '"version"')
    assert_no_failure("lnd")

    # Test certificate generation
    cert_alt_names = succeed("</secrets/lnd-cert openssl x509 -noout -ext subjectAltName")
    assert_str_matches(cert_alt_names, '10.0.0.1')
    assert_str_matches(cert_alt_names, '20.0.0.1')
    assert_str_matches(cert_alt_names, 'example.com')

@test("lnd-macaroons")
def _():
    # Custom macaroons are created by a root script that operates in dirs that are
    # writable by the lnd user.
    # Test that the script doesn't follow symlinks placed there by the lnd user.
    #
    # Services like lightning-pool and btcpayserver read the live macaroons, so
    # the test never touches them: the script writes to a test runtime dir, and
    # for the admin macaroon it runs in a private mount namespace where a test dir
    # is bind-mounted over the lnd network dir.
    assert_running("lnd")
    data = test_data["lnd-macaroons"]
    name, user = next(iter(data["users"].items()))
    as_lnd = f"runuser -u {data['user']} --"
    runtime_dir = "/run/lnd-macaroons-test"
    network_dir = "/run/lnd-macaroons-test-network"
    macaroon = f"{runtime_dir}/{name}.macaroon"
    script = succeed(
        "systemctl show lnd -p ExecStartPost --value"
        " | grep -oE '/nix/store/[^ ]+-lnd-create-macaroons' | head -1"
    ).strip()
    create_macaroons = f"RUNTIME_DIRECTORY={runtime_dir} {script} 2>&1"
    live_macaroons = "stat -c '%n %i %Y' /run/lnd/*.macaroon"

    canary = "/run/lnd-test-canary"
    canary_dir = "/run/lnd-test-canary-dir"
    succeed(
        f"install -m 600 <(echo canary) {canary}",
        f"mkdir -m 700 {canary_dir}",
        f"install -d -m 750 -o {data['user']} {runtime_dir} {network_dir}",
    )
    live_before = succeed(live_macaroons)

    def assert_macaroon_created():
        assert_full_match(f"stat -c '%F %U %a' {macaroon}", f"regular file {user} 440\n")

    def assert_canary_untouched():
        assert_full_match(f"cat {canary}", "canary\n")
        assert_full_match(f"stat -c '%U %a' {canary}", "root 600\n")
        assert_full_match(f"ls -A {canary_dir}", "")

    # Macaroon path is a symlink to a root-only file
    succeed(f"{as_lnd} ln -sfn {canary} {macaroon}", create_macaroons)
    assert_canary_untouched()
    assert_macaroon_created()

    # Macaroon path is a symlink to a root-only dir
    succeed(f"{as_lnd} ln -sfn {canary_dir} {macaroon}", create_macaroons)
    assert_canary_untouched()
    assert_macaroon_created()

    # Admin macaroon is a symlink to a root-only file.
    # The file must not be read and sent to lnd.
    succeed(f"{as_lnd} ln -s {canary} {network_dir}/admin.macaroon")
    status, output = machine.execute(
        "unshare --mount --propagation private sh -c"
        f" 'mount --bind {network_dir} {data['networkDir']} && {create_macaroons}'"
    )
    denied = f"{data['networkDir']}/admin.macaroon: Permission denied"
    if status == 0 or denied not in output:
        raise Exception(f"Unexpected result when reading the admin macaroon: {status}, '{output}'")
    assert_canary_untouched()

    # The live macaroons were never replaced
    assert_full_match(live_macaroons, re.escape(live_before))
    succeed(f"rm -r {canary} {canary_dir} {runtime_dir} {network_dir}")

@test("lndconnect-onion-lnd")
def _():
    assert_running("lnd")
    assert_matches("runuser -u operator -- lndconnect --url", ".onion")

@test("lnconnect-onion-clnrest")
def _():
    assert_running("clightning")
    assert_matches("runuser -u operator -- lnconnect-clnrest --url", ".onion")

@test("lndconnect-onion-clightning")
def _():
    assert_running("clightning-rest")
    assert_matches("runuser -u operator -- lndconnect-clightning --url", ".onion")

@test("lndconnect-local-bind")
def _():
    for service in test_data["lndconnect-local-bind"]:
        port = service["port"]
        assert_running(service["unit"])
        wait_for_open_port("127.0.0.1", port)
        # The REST server must listen on localhost only
        assert_full_match(
            f"ss -Htnl 'sport = :{port}' | awk '{{print $4}}' | sort -u", f"127.0.0.1:{port}\n"
        )

@test("lightning-loop")
def _():
    assert_running("lightning-loop")
    assert_matches("runuser -u operator -- loop --version", "version")
    # Check that lightning-loop fails with the right error, making sure
    # lightning-loop can connect to lnd
    machine.wait_until_succeeds(
        log_has_string(
            "lightning-loop",
            "Waiting for lnd to be fully synced to its chain backend, this might take a while",
        )
    )

@test("lightning-pool")
def _():
    assert_running("lightning-pool")
    assert_matches("su operator -c 'pool --version'", "version")
    # Check that lightning-pool fails with the right error, making sure
    # lightning-pool can connect to lnd
    machine.wait_until_succeeds(
        log_has_string(
            "lightning-pool",
            "Waiting for lnd to be fully synced to its chain backend, this might take a while",
        )
    )

@test("charge-lnd")
def _():
    # charge-lnd is a oneshot service that is started by a timer under regular operation
    succeed("systemctl start charge-lnd")
    assert_no_failure("charge-lnd")

@test("btcpayserver")
def _():
    assert_running("nbxplorer")
    machine.wait_until_succeeds(log_has_string("nbxplorer", "BTC: RPC connection successful"))
    wait_for_open_port(ip("nbxplorer"), 24444)

    assert_running("btcpayserver")
    machine.wait_until_succeeds(log_has_string("btcpayserver", "Now listening on"))
    wait_for_open_port(ip("btcpayserver"), 23000)
    # test lnd custom macaroon
    assert_matches(
        "runuser -u btcpayserver -- curl -fsS --cacert /secrets/lnd-cert "
        '--header "Grpc-Metadata-macaroon: $(xxd -ps -u -c 1000 /run/lnd/btcpayserver.macaroon)" '
        f"-X GET https://{ip('lnd')}:8080/v1/getinfo | jq",
        '"version"',
    )
    # Test web server response
    assert_matches(f"curl -fsS -L {ip('btcpayserver')}:23000", "Welcome to BTCPay Server")

@test("rtl")
def _():
    assert_running("rtl")
    machine.wait_until_succeeds(
        log_has_string("rtl", "Server is up and running")
    )

@test("rtl-credentials")
def _():
    # The lnd macaroon and the clightning rune are copied to RTL by root scripts.
    # The source dirs are writable by lnd/clightning and the destination dir is
    # writable by rtl.
    # Test that the scripts don't follow symlinks placed there by these users.
    assert_running("rtl")
    data = test_data["rtl-credentials"]
    data_dir = data["dataDir"]
    as_rtl = f"runuser -u {data['user']} --"
    exec_start_pre = succeed("systemctl show rtl -p ExecStartPre --value")

    def get_script(name):
        match = re.search(rf"/nix/store/[^ ;]+-{name}", exec_start_pre)
        if not match:
            raise Exception(f"Script {name} not found in ExecStartPre: '{exec_start_pre}'")
        return match.group(0)

    canary = "/run/rtl-test-canary"
    canary_dir = "/run/rtl-test-canary-dir"
    succeed(f"install -m 600 <(echo canary) {canary}", f"mkdir -m 700 {canary_dir}")

    def assert_canary_untouched():
        assert_full_match(f"cat {canary}", "canary\n")
        assert_full_match(f"stat -c '%U %a' {canary}", "root 600\n")
        assert_full_match(f"stat -c '%U %a' {canary_dir}", "root 700\n")
        assert_full_match(f"ls -A {canary_dir}", "")

    def assert_dest_ok(dest, expected_content_cmd):
        assert_full_match(f"stat -c '%F %U %G %a' {dest}",
                          f"regular file {data['user']} {data['group']} 640\n")
        succeed(f"cmp {dest} <({expected_content_cmd})")

    def check(script, owner, src, dest, expected_content_cmd):
        as_owner = f"runuser -u {owner} --"

        # Destination is a symlink to a root-only file
        succeed(f"{as_rtl} ln -sfn {canary} {dest}", script)
        assert_canary_untouched()
        assert_dest_ok(dest, expected_content_cmd)

        # Source is a symlink to a root-only file.
        # It must not be read and copied to the destination.
        succeed(
            f"{as_owner} mv -T {src} {src}.orig",
            f"{as_owner} ln -s {canary} {src}",
        )
        status, output = machine.execute(f"{script} 2>&1")
        succeed(f"{as_owner} mv -T {src}.orig {src}")
        if status == 0 or "Permission denied" not in output:
            raise Exception(f"Unexpected result when reading {src}: {status}, '{output}'")
        machine.fail(f"grep -q canary {dest}")
        assert_canary_untouched()

        # Source is empty.
        # The script must fail with a clear error and keep the current destination.
        succeed(
            f"{as_owner} mv -T {src} {src}.orig",
            f"{as_owner} cp /dev/null {src}",
        )
        status, output = machine.execute(f"{script} 2>&1")
        succeed(f"{as_owner} mv -T {src}.orig {src}")
        if status == 0 or f"Error: '{src}' is empty" not in output:
            raise Exception(f"Unexpected result when reading empty {src}: {status}, '{output}'")
        assert_dest_ok(dest, expected_content_cmd)

        succeed(script)
        assert_dest_ok(dest, expected_content_cmd)

    if lnd := data["lnd"]:
        script = get_script("rtl-copy-macaroon")
        admin_macaroon = f"{lnd['networkDir']}/admin.macaroon"
        macaroons_dir = f"{data_dir}/macaroons"
        dest = f"{macaroons_dir}/admin.macaroon"

        # Destination dir is a symlink to a root-only dir.
        # Neither the script nor systemd-tmpfiles may write to the dir or change its owner.
        succeed(
            f"{as_rtl} mv -T {macaroons_dir} {macaroons_dir}.orig",
            f"{as_rtl} ln -s {canary_dir} {macaroons_dir}",
        )
        machine.execute(script)
        machine.execute(f"systemd-tmpfiles --create --prefix={macaroons_dir}")
        succeed(f"{as_rtl} rm {macaroons_dir}", f"{as_rtl} mv -T {macaroons_dir}.orig {macaroons_dir}")
        assert_canary_untouched()

        # Earlier versions created the destination dir as root.
        # systemd-tmpfiles changes the owner, so that the rtl user can update the macaroon.
        succeed(
            f"chown root:root {macaroons_dir}",
            f"chmod 755 {macaroons_dir}",
            f"systemd-tmpfiles --create --prefix={macaroons_dir}",
        )
        assert_full_match(f"stat -c '%U %G %a' {macaroons_dir}",
                          f"{data['user']} {data['group']} 770\n")
        succeed(f"{as_rtl} cp /dev/null {dest}", script)
        assert_dest_ok(dest, f"cat {admin_macaroon}")

        check(script, lnd["user"], admin_macaroon, dest, f"cat {admin_macaroon}")

    if cln := data["clightning"]:
        script = get_script("rtl-create-clnrest-rune-file")
        admin_rune = f"{cln['networkDir']}/admin-rune"
        check(script, cln["user"], admin_rune, f"{data_dir}/clightning-admin-rune",
              f"printf 'LIGHTNING_RUNE=\"%s\"\\n' \"$(cat {admin_rune})\"")

    succeed(f"rm -r {canary} {canary_dir}")

@test("clightning-rest")
def _():
    assert_running("clightning-rest")
    machine.wait_until_succeeds(
        log_has_string("clightning-rest", "cl-rest api server is ready and listening")
    )

@test("clightning-rest-local-bind")
def _():
    assert_running("clightning-rest")
    machine.wait_until_succeeds(
        log_has_string("clightning-rest", "cl-rest doc server is ready and listening")
    )
    # The REST and doc servers must listen on localhost only
    for port in test_data["clightning-rest-local-bind"]:
        wait_for_open_port("127.0.0.1", port)
        assert_full_match(
            f"ss -Htnl 'sport = :{port}' | awk '{{print $4}}' | sort -u", f"127.0.0.1:{port}\n"
        )

@test("mempool")
def _():
    assert_running("mempool")
    assert_running("nginx")
    machine.wait_until_succeeds(
        log_has_string("mempool", "Mempool Server is running on port 8999")
    )
    assert_matches(f"curl -L {ip('nginx')}:60845", "mempool - Bitcoin Explorer")

@test("nodeinfo")
def _():
    status, _ = machine.execute("systemctl is-enabled --quiet onion-addresses 2> /dev/null")
    if status == 0:
        machine.wait_for_unit("onion-addresses")
    json_info = succeed("runuser -u operator -- nodeinfo")
    info = json.loads(json_info)
    assert info["bitcoind"]["local_address"]

@test("secure-node")
def _():
    assert_running("onion-addresses")

# Run this test before the following tests that shut down services
# (and their corresponding network namespaces).
@test("netns-isolation")
def _():
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
    assert_unreachable("bitcoind", ["btcpayserver", "rtl", "lightning-loop"])
    assert_unreachable("btcpayserver", ["bitcoind", "lightning-loop"])

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

    # The netns-exec wrapper should keep its capability and restrictive owner/mode
    assert_matches("getcap /run/wrappers/bin/netns-exec", "cap_sys_admin")
    assert_full_match("stat -c '%U %a' /run/wrappers/bin/netns-exec", "operator 500\n")

    # netns-exec should reject relative command paths, so PATH can't redirect the exec target
    status, out = machine.execute("runuser -u operator -- netns-exec nb-bitcoind ip a 2>&1")
    assert status != 0 and "absolute path" in out, f"status {status}, output: {out}"

    # netns-exec should fail for unauthorized namespaces.
    # The allowlist is empty, so every netns is rejected.
    status, out = machine.execute(
        "runuser -u operator -- netns-exec nb-bitcoind /run/current-system/sw/bin/ip a 2>&1"
    )
    assert status != 0 and "nb-bitcoind is not an allowed netns" in out, f"status {status}, output: {out}"

    # netns-exec should only be executable by the operator user.
    # User `unauthorized` is a member of group `users`, like all normal users.
    # Netns `nb-clightning` is rejected by netns-exec before it accesses the
    # netns, so the error below can only originate from the exec permissions.
    assert_matches(
        "runuser -u unauthorized -- netns-exec nb-clightning /run/current-system/sw/bin/ip a 2>&1 || true",
        "Permission denied",
    )


# Impure: stops bitcoind (and dependent services)
@test("backups")
def _():
    # For testing that bitcoind wallets are backed up
    succeed("bitcoin-cli -named createwallet wallet_name=test blank=true >/dev/null")

    succeed("systemctl stop bitcoind")
    assert_matches("systemctl show -p ExecMainStatus --value bitcoind", "^0$")
    succeed("systemctl start duplicity")
    machine.wait_until_succeeds(log_has_string("duplicity", "duplicity.service: Deactivated successfully."))
    run_duplicity = "export $(cat /secrets/backup-encryption-env); duplicity"
    # Files in backup and /var/lib should be identical
    assert_matches(
        f"{run_duplicity} verify --archive-dir /var/lib/duplicity file:///var/lib/localBackups /var/lib",
        "no sync needed",
    )
    # Backup should include important files
    files = {
        "bitcoind": "var/lib/bitcoind/test/wallet.dat",
        "clightning": "var/lib/clightning/bitcoin/hsm_secret",
        "lnd": "var/lib/lnd/lnd-seed-mnemonic",
        "btcpayserver": "var/backup/postgresql/btcpaydb.sql.gz",
    }
    actual_files = succeed(f"{run_duplicity} list-current-files file:///var/lib/localBackups")

    def assert_file_exists(file):
        if file not in actual_files:
            raise Exception(f"Backup file '{file}' is missing.")

    for test, file in files.items():
        if test in enabled_tests:
            assert_file_exists(file)

    assert_file_exists("secrets/lnd-wallet-password")

# Impure: restarts services
@test("restart-bitcoind")
def _():
    # Sanity-check system by restarting bitcoind.
    succeed("systemctl restart bitcoind")

@test("regtest")
def _():
    def enabled(unit):
        if unit in enabled_tests:
            # Wait because the unit might have been restarted in the preceding
            # 'restart-bitcoind' test
            machine.wait_for_unit(unit)
            return True
        else:
            return False

    def get_block_height(ip, port):
        return (
            """echo '{"method": "blockchain.headers.subscribe", "id": 0}'"""
            f" | nc {ip} {port} | head -1 | jq -M .result.height"
        )

    num_blocks = test_data["num_blocks"]

    if enabled("electrs"):
        machine.wait_until_succeeds(log_has_string("electrs", "serving Electrum RPC"))
        assert_full_match(get_block_height(ip('electrs'), 50001), f"{num_blocks}\n")

    if enabled("fulcrum"):
        machine.wait_until_succeeds(log_has_string("fulcrum", "listening for connections"))
        assert_full_match(get_block_height(ip('fulcrum'), 50002), f"{num_blocks}\n")

    if enabled("clightning"):
        machine.wait_until_succeeds(
            f"[[ $(runuser -u operator -- lightning-cli getinfo | jq -M .blockheight) == {num_blocks} ]]"
        )

    if enabled("lnd"):
        machine.wait_until_succeeds(
            f"[[ $(runuser -u operator -- lncli getinfo | jq -M .block_height) == {num_blocks} ]]"
        )

    if enabled("lightning-loop"):
        machine.wait_until_succeeds(
            log_has_string("lightning-loop", f"Starting event loop at height {num_blocks}")
        )
        succeed("runuser -u operator -- loop getparams")

    if enabled("lightning-pool"):
        machine.wait_until_succeeds(
            log_has_string("lightning-pool", "lnd is now fully synced to its chain backend")
        )
        succeed("runuser -u operator -- pool orders list")

    if enabled("btcpayserver"):
        machine.wait_until_succeeds(log_has_string("nbxplorer", f"At height: {num_blocks}"))

    if enabled("mempool"):
        assert_running("nginx")
        assert_full_match(
            f"curl -fsS http://{ip('nginx')}:60845/api/v1/blocks/tip/height", str(num_blocks)
        )

@test("trustedcoin")
def _():
    def expect_clightning_log(str):
        machine.wait_until_succeeds(log_has_string("clightning", str))

    expect_clightning_log(r"plugin-trustedcoin\b.*?\bbitcoind RPC working")
    if "regtest" in enabled_tests:
        num_blocks = test_data["num_blocks"]
        expect_clightning_log(rf"plugin-trustedcoin\b.*?\breturning block {num_blocks}")


if "netns-isolation" in enabled_tests:
    def ip(name):
        return test_data["netns"][name]["address"]
else:
    def ip(_):
        return "127.0.0.1"
