from collections import OrderedDict
from urllib.parse import parse_qs, urlparse
import base64
import hmac
import json
import os
import re
import shlex

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

def current_run_log_has_string(unit, str):
    """Like log_has_string, but ignores runs of the unit before its last (re)start"""
    invocation = f"$(systemctl show -p InvocationID --value {unit})"
    return f"journalctl -b --output=cat _SYSTEMD_INVOCATION_ID={invocation} --grep='{str}'"

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

@test("secrets-no-argv")
def _():
    # Passwords must not be passed as command-line arguments during secret
    # generation. Any local user can read those via /proc/<pid>/cmdline.
    gen_dir = "/tmp/secrets-no-argv"
    # A hand-placed password file with a CRLF line ending. Clients send the
    # password via `$(cat file)`, which keeps the CR, so the HMAC must too.
    crlf_password = "CrLfPassword12345\r"
    succeed(
        f"rm -rf {gen_dir} && mkdir -m 700 {gen_dir} && cd {gen_dir} && "
        "printf 'CrLfPassword12345\\r\\n' > bitcoin-rpcpassword-public && "
        f"strace -f -qq -e trace=execve -s 4096 -o {gen_dir}.trace "
        f"{test_data['secrets-no-argv']['generator']}"
    )
    trace = succeed(f"cat {gen_dir}.trace")
    assert_str_matches(trace, "rpcauth")
    files = succeed(f"cd {gen_dir} && ls -1").split()
    for file in files:
        if "password" not in file:
            continue
        password = succeed(f"cat {gen_dir}/{file}").rstrip("\n")
        # Skip trivial test passwords (like the 'rtl-password' override)
        if len(password) >= 16 and password in trace:
            raise Exception(f"Secret '{file}' was passed as a command-line argument")

    def assert_hmac_matches(user):
        password = succeed(f"cat {gen_dir}/bitcoin-rpcpassword-{user}").rstrip("\n")
        hmac_line = succeed(f"cat {gen_dir}/bitcoin-HMAC-{user}")
        assert_str_matches(hmac_line, r"\A[0-9a-f]{32}\$[0-9a-f]{64}\n\Z")
        salt, digest = hmac_line.rstrip("\n").split("$")
        expected = hmac.new(salt.encode(), password.encode(), "SHA256").hexdigest()
        if digest != expected:
            raise Exception(f"bitcoin-HMAC-{user} doesn't match bitcoin-rpcpassword-{user}")
        return password

    # The HMACs written by secret generation match their passwords
    rpc_users = [f.removeprefix("bitcoin-rpcpassword-") for f in files
                 if f.startswith("bitcoin-rpcpassword-")]
    assert rpc_users
    for user in rpc_users:
        password = assert_hmac_matches(user)
        if user == "public":
            assert password == crlf_password, repr(password)

    generate = f"cd {gen_dir} && {test_data['secrets-no-argv']['generator']}"
    password_file = f"{gen_dir}/bitcoin-rpcpassword-public"
    hmac_file = f"{gen_dir}/bitcoin-HMAC-public"

    # A failed HMAC generation leaves no HMAC file behind. Make it fail with a
    # password "file" that can't be read.
    succeed(f"rm {password_file} {hmac_file}", f"mkdir {password_file}")
    status, out = machine.execute(f"{generate} 2>&1")
    assert status != 0 and "IsADirectoryError" in out, out
    succeed(f"[[ ! -e {hmac_file} && ! -e {hmac_file}.tmp ]]")

    # An empty HMAC file is regenerated, even when it is newer than the password
    succeed(f"rmdir {password_file}",
            f"echo validPassword123456 > {password_file}",
            f"touch -d '+1 hour' {hmac_file}",
            generate)
    assert assert_hmac_matches("public") == "validPassword123456"

    # An empty password file is regenerated, and so is its HMAC
    succeed(f"truncate -s 0 {password_file}", generate)
    assert_str_matches(succeed(f"cat {password_file}"), r"\A[a-zA-Z0-9]{20}\n\Z")
    assert_hmac_matches("public")

    # A password file with only a newline is not regenerated (it isn't empty),
    # but must not get an HMAC of the empty password either
    succeed(f"rm {hmac_file}", f"echo > {password_file}")
    status, out = machine.execute(f"{generate} 2>&1")
    assert status != 0 and "contains no password" in out, out
    succeed(f"[[ ! -e {hmac_file} && ! -e {hmac_file}.tmp ]]")
    succeed(f"rm -rf {gen_dir} {gen_dir}.trace")

@test("bitcoind")
def _():
    assert_running("bitcoind")
    machine.wait_until_succeeds("bitcoin-cli getnetworkinfo")
    assert_matches("runuser -u operator -- bitcoin-cli getnetworkinfo | jq", '"version"')

    # The cookie lives in a runtime directory that only the bitcoin user can write
    cookie = "/run/bitcoind/.cookie"
    assert_full_match("stat -c '%U:%G %a' /run/bitcoind", "bitcoin:bitcoin 750\n")
    assert_full_match(f"stat -c '%a' {cookie}", "640\n")
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
def _():
    data = test_data["bitcoind-rest"]
    # Evaluation checks run in Nix; report the names of any failing cases.
    assert not data["failedCases"], f"REST assertion cases failed: {data['failedCases']}"

    rest = f"http://{ip('bitcoind')}:{data['rpcPort']}/rest"
    url = f"{rest}/chaininfo.json"
    if not data["enable"]:
        assert_full_match(f"curl -sS -o /dev/null -w '%{{http_code}}' {url}", "404")
        return

    # REST is unauthenticated
    assert_matches(f"runuser -u nobody -- curl -fsS {url}", '"chain"')
    # Fetch a block by height, in the binary format electrs uses
    genesis = succeed(f"curl -fsS {rest}/blockhashbyheight/0.json | jq -r .blockhash").strip()
    assert_full_match(f"curl -fsS {rest}/block/{genesis}.json | jq -r .hash", f"{genesis}\n")
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

@test("rpc-whitelist")
def _():
    data = test_data["rpc-whitelist"]
    # Arguments are chosen so that each call fails harmlessly with an RPC error
    # if it gets past the whitelist
    calls = {
        "getblockcount": "getblockcount",
        "scantxoutset": "scantxoutset status",
        "getblocktemplate": """getblocktemplate '{"rules":["segwit"]}'""",
        "fundrawtransaction": "fundrawtransaction 00",
        "gettxoutsetinfo": "gettxoutsetinfo none",
        "getblockfrompeer": f"getblockfrompeer {'0' * 64} 0",
        "setban": "setban 192.0.2.1 remove",
        "generatetoaddress": "generatetoaddress 1 invalid",
    }

    def is_forbidden(user, method):
        _, out = machine.execute(
            f"bitcoin-cli -rpcuser={user} -rpcpassword=$(cat /secrets/bitcoin-rpcpassword-{user})"
            f" {calls[method]} 2>&1"
        )
        if "Could not connect to the server" in out or "Authorization failed" in out:
            raise Exception(f"RPC call {method} as user {user} failed: {out}")
        return "server returned HTTP error 403" in out

    def assert_rpc_access(user, allowed, denied):
        for method in allowed:
            if is_forbidden(user, method):
                raise Exception(f"RPC user {user} should be allowed to call {method}")
        for method in denied:
            if not is_forbidden(user, method):
                raise Exception(f"RPC user {user} should not be allowed to call {method}")

    machine.wait_until_succeeds("bitcoin-cli getnetworkinfo")

    public_allowed = ["getblockcount"]
    public_denied = ["scantxoutset", "getblocktemplate", "fundrawtransaction"]
    (public_allowed if data["clightning-bcli"] else public_denied).append("getblockfrompeer")
    (public_allowed if data["mempool"] else public_denied).append("gettxoutsetinfo")
    assert_rpc_access("public", public_allowed, public_denied)

    if data["btcpayserver"]:
        btcpay_allowed = ["getblockcount", "getblockfrompeer"]
        btcpay_denied = [
            "scantxoutset", "getblocktemplate", "fundrawtransaction", "setban", "generatetoaddress"
        ]
        assert_rpc_access("btcpayserver", btcpay_allowed, btcpay_denied)

@test("electrs")
def _():
    assert_running("electrs")
    # electrs.toml holds the public RPC password
    toml = "/var/lib/electrs/electrs.toml"
    assert_full_match(f"stat -c '%a %U' {toml}", "600 electrs\n")
    # A file with laxer permissions (created by earlier versions) is replaced
    succeed(f"chmod 644 {toml} && systemctl restart electrs")
    assert_full_match(f"stat -c '%a %U' {toml}", "600 electrs\n")
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
    # fulcrum.conf holds the public RPC password
    conf = "/var/lib/fulcrum/fulcrum.conf"
    assert_full_match(f"stat -c '%a %U' {conf}", "600 fulcrum\n")
    # A file with laxer permissions (created by earlier versions) is replaced
    succeed(f"chmod 644 {conf} && systemctl restart fulcrum")
    assert_full_match(f"stat -c '%a %U' {conf}", "600 fulcrum\n")
    # Later tests expect a started fulcrum, not one that is still starting
    machine.wait_until_succeeds(current_run_log_has_string("fulcrum", "started ok"))

@test("rbitcoin")
def _():
    assert_running("rbitcoin")
    # The operator reaches the node through the unix socket
    machine.wait_until_succeeds("runuser -u operator -- rbitcoin-cli getblockcount")

    if not test_data["rbitcoin"]["rpc"]:
        return
    cookie = "/run/rbitcoin/rpc.cookie"
    assert_full_match(f"stat -c '%a %U %G' {cookie}", "640 rbitcoin rbitcoinrpc\n")
    # Only group `rbitcoinrpc` can read the cookie
    machine.fail(f"runuser -u operator -- cat {cookie}")
    # The cookie authenticates Bitcoin Core style HTTP Basic RPC, other credentials don't
    rpc = (
        """curl -s -o /dev/null -w '%{http_code}' --data-binary """
        """'{"jsonrpc":"1.0","id":0,"method":"getblockcount","params":[]}' """
        f"http://{ip('rbitcoin')}:18453/"
    )
    assert_full_match(f"{rpc} --user \"$(cat {cookie})\"", "200")
    assert_full_match(f"{rpc} --user __cookie__:wrong", "401")

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
    # Services like btcpayserver read the live macaroons, so
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

@test("lnconnect-clnrest-cert")
def _():
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
def _():
    for service in test_data["lndconnect-local-bind"]:
        port = service["port"]
        assert_running(service["unit"])
        wait_for_open_port("127.0.0.1", port)
        # The REST server must listen on localhost only
        assert_full_match(
            f"ss -Htnl 'sport = :{port}' | awk '{{print $4}}' | sort -u", f"127.0.0.1:{port}\n"
        )

@test("charge-lnd")
def _():
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
def _():
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

@test("mempool")
def _():
    assert_running("mempool")
    assert_running("nginx")
    machine.wait_until_succeeds(
        log_has_string("mempool", "Mempool Server is running on port 8999")
    )
    # config.json holds the public RPC password
    conf = "/var/cache/mempool/config.json"
    assert_full_match(f"stat -c '%a %U' {conf}", "600 mempool\n")
    # A file with laxer permissions (created by earlier versions) is replaced
    succeed(f"chmod 644 {conf} && systemctl restart mempool")
    assert_full_match(f"stat -c '%a %U' {conf}", "600 mempool\n")
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

@test("onion-addresses")
def _():
    # The onion-addresses service runs as root.
    # It writes to per-user dirs that are owned by the target users and it reads
    # Tor hostname files in dirs that are writable by user tor.
    # Test that it doesn't follow symlinks placed there and that it only copies
    # valid onion addresses.
    data = test_data["onion-addresses"]
    data_dir = data["dataDir"]
    # On the unfixed service, the first user's dir is created right before
    # the service waits for this user's first hostname file
    user = next(user for user in sorted(data["access"]) if data["access"][user])
    service = data["access"][user][0]
    dest = f"{data_dir}/{user}/{service}"
    hostname = f"/var/lib/tor/onion/{service}/hostname"
    hostname_orig = f"{hostname}.test-orig"
    unit = "onion-addresses"
    fake_address = "a" * 56 + ".onion"

    machine.wait_for_unit(unit)
    address = succeed(f"cat {hostname}")

    def assert_addresses_copied():
        assert_full_match(f"stat -c '%F %U %a' {dest}", f"regular file {user} 600\n")
        assert_full_match(f"cat {dest}", re.escape(address))
        for srv, srv_user in data["serviceUsers"].items():
            path = f"{data_dir}/services/{srv}"
            assert_full_match(f"stat -c '%F %U %a' {path}", f"regular file {srv_user} 400\n")
            assert_full_match(f"cat {path}", re.escape(succeed(f"cat /var/lib/tor/onion/{srv}/hostname")))

    def wait_until_finished():
        machine.wait_until_succeeds(f"test $(systemctl show -p ActiveState --value {unit}) != activating")

    canary = "/run/onion-addresses-test-canary"
    canary_dir = "/run/onion-addresses-test-canary-dir"
    succeed(f"install -m 600 <(echo canary) {canary}", f"mkdir -m 700 {canary_dir}")

    def assert_canary_untouched():
        assert_full_match(f"cat {canary}", "canary\n")
        assert_full_match(f"stat -c '%U %a' {canary}", "root 600\n")
        assert_full_match(f"ls -A {canary_dir}", "")

    def plant_symlink_while_running(target):
        # Hide the hostname file so that the service waits for it.
        # Meanwhile, place a symlink at the destination path as the target user.
        succeed(
            f"mv -T {hostname} {hostname_orig}",
            f"systemctl restart --no-block {unit}",
        )
        machine.wait_until_succeeds(
            f"cat /sys/fs/cgroup/system.slice/{unit}.service/cgroup.procs"
            " | xargs -I{} cat /proc/{}/comm | grep -qx sleep"
        )
        succeed(f"runuser -u {user} -- ln -sfn {target} {dest}")
        succeed(f"mv -T {hostname_orig} {hostname}")
        wait_until_finished()
        succeed(f"systemctl is-active {unit}")
        assert_canary_untouched()
        assert_addresses_copied()

    # Destination is a symlink to a root-only file
    plant_symlink_while_running(canary)
    # Destination is a symlink to a root-only dir
    plant_symlink_while_running(canary_dir)

    def assert_rejected(*replace_hostname):
        succeed(f"mv -T {hostname} {hostname_orig}", *replace_hostname)
        # A blocked unit must not count as a rejection
        status, _ = machine.execute(f"timeout 60 systemctl restart {unit}")
        succeed(f"rm -f {hostname}", f"mv -T {hostname_orig} {hostname}")
        if status == 124:
            raise Exception("onion-addresses blocked on the hostname file")
        if status == 0:
            raise Exception("onion-addresses accepted an invalid hostname file")
        machine.fail(f"grep -rq 'rpcallowip\\|{fake_address}' {data_dir}")

        # Check every destination: the selected user may have only one address.
        def check_destination(srv, path, owner, mode):
            if srv == service:
                succeed(f"test ! -e {path} && test ! -L {path}")
                return

            assert_full_match(
                f"stat -c '%F %U %a' {path}",
                f"regular file {owner} {mode}\n",
            )
            expected = succeed(f"cat /var/lib/tor/onion/{srv}/hostname")
            assert_full_match(f"cat {path}", re.escape(expected))

        for owner, services in data["access"].items():
            for srv in services:
                check_destination(srv, f"{data_dir}/{owner}/{srv}", owner, 600)

        for srv, owner in data["serviceUsers"].items():
            check_destination(srv, f"{data_dir}/services/{srv}", owner, 400)

    # Extra lines would be spliced into config files like bitcoin.conf
    assert_rejected(
        f"install -o tor -g tor -m 600 <(cat {hostname_orig}; echo rpcallowip=0.0.0.0/0) {hostname}"
    )
    # Hostname file is a symlink to a root-only file.
    # It must not be read by root.
    onion_canary = "/run/onion-addresses-test-canary.onion"
    succeed(f"install -m 600 <(echo {fake_address}) {onion_canary}")
    assert_rejected(f"ln -s {onion_canary} {hostname}")
    # Hostname file is a FIFO. Reading it must time out instead of blocking the unit.
    assert_rejected(f"runuser -u tor -- mkfifo {hostname}")

    succeed(f"rm -r {canary} {canary_dir} {onion_canary}", f"systemctl restart {unit}")
    machine.succeed(f"systemctl reset-failed {unit}")
    assert_addresses_copied()

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

# Impure: stops, starts and restarts bitcoind and its dependents
@test("restart-bitcoind")
def _():
    # lnd, electrs and clightning `require` bitcoind and are `wantedBy` it.
    # A deploy that changes the bitcoind unit stops bitcoind and starts it
    # again. The stop propagates to the dependents. The start must bring them
    # back. An explicit stop must keep everything down.
    dependents = [unit for unit in ["lnd", "clightning", "electrs"] if unit in enabled_tests]

    def state(unit):
        return succeed(f"systemctl show -P ActiveState {unit}").strip()

    def inactive_since(unit):
        return succeed(f"systemctl show -P InactiveEnterTimestampMonotonic {unit}").strip()

    def wait_for_bitcoind():
        machine.wait_until_succeeds("runuser -u operator -- bitcoin-cli getnetworkinfo")

    # 0. 'backups' and 'stop-electrs' may have left units down. Start each one
    # explicitly so that only the steps below rely on `wantedBy`.
    succeed("systemctl start bitcoind")
    wait_for_bitcoind()
    for unit in dependents:
        succeed(f"systemctl start {unit}")
        machine.wait_for_unit(unit)

    # A dependent can end up `failed` instead of `inactive` when it hits its
    # stop timeout (clightning with clboss has TimeoutStopSec=500ms here).
    # Either way it's down, and a stop job never triggers Restart=.
    stopped = "inactive|failed"

    # 1. An explicit stop propagates and sticks.
    succeed("systemctl stop bitcoind")
    for unit in dependents:
        machine.wait_until_succeeds(f"[[ $(systemctl show -P ActiveState {unit}) =~ ^({stopped})$ ]]")
    stopped_at = {unit: inactive_since(unit) for unit in ["bitcoind"] + dependents}
    # Longer than every dependent's RestartSec (10s), so a restart that pulled
    # bitcoind back up would show here.
    machine.sleep(25)
    for unit, since in stopped_at.items():
        assert re.fullmatch(stopped, state(unit)), f"{unit} came back after an explicit stop"
        assert inactive_since(unit) == since, f"{unit} was restarted after an explicit stop"

    # 2. The start half of a deploy brings the dependents back.
    # `wait_for_unit` raises on `failed` even with a start job queued, so clear
    # that state first. `inactive` with no job queued still raises.
    succeed(f"systemctl reset-failed {' '.join(dependents)}")
    succeed("systemctl start bitcoind")
    wait_for_bitcoind()
    for unit in dependents:
        machine.wait_for_unit(unit)
    # Give them time to connect, then check they are still up.
    machine.sleep(15)
    for unit in dependents:
        machine.wait_for_unit(unit)

    # 3. A plain restart propagates and everything is up afterwards.
    succeed("systemctl restart bitcoind")
    wait_for_bitcoind()
    for unit in dependents:
        machine.wait_for_unit(unit)

# Impure: restarts services
@test("config-replace")
def _():
    # Services write their config at start, and the config dirs are writable by
    # the operator (bitcoind, clightning) or the service user.
    # Test that symlinks to files and directories are replaced by regular files
    # with the expected owner and mode, without changing the symlink targets.
    for data in test_data["config-replace"]:
        unit, file, user, planter = data["unit"], data["file"], data["user"], data["planter"]
        with machine.nested(f"config file: {file}"):
            # The unit might still be restarting after the preceding 'restart-bitcoind' test
            succeed(f"systemctl start {unit}")
            orig = f"{file}.orig"
            # The target must be inside the config dir, which is the only path the
            # service can write (ProtectSystem, ProtectHome, PrivateTmp)
            target = f"{os.path.dirname(file)}/config-replace-target"
            for target_type in ("file", "directory"):
                with machine.nested(f"symlink to {target_type}"):
                    # A started unit may still be reading its config. Stop it
                    # before planting the symlink for the next start.
                    succeed(f"systemctl stop {unit}")
                    if target_type == "file":
                        # Identical content also covers services that skip an
                        # update when the content is unchanged.
                        succeed(
                            f"cat {file} > {target}",
                            f"chown {planter} {target}",
                            f"chmod 666 {target}",
                        )
                        contents = f"cat {target}"
                    else:
                        # Without install -T, install writes inside this writable
                        # directory and leaves the config symlink in place.
                        succeed(f"install -d -o {user} -m 700 {target}")
                        contents = f"find {target} -mindepth 1 -print"
                    metadata = f"stat -c '%i %U %G %a %s %y %z' {target}"
                    before_contents = succeed(contents)
                    before_metadata = succeed(metadata)
                    succeed(
                        f"runuser -u {planter} -- sh -c 'mv {file} {orig} && ln -s {target} {file}'",
                        f"systemctl start {unit}",
                    )
                    machine.wait_for_unit(unit)
                    assert_full_match(
                        f"stat -c '%U %a %F' {file}", f"{user} {data['mode']} regular file\n"
                    )
                    assert_full_match(contents, re.escape(before_contents))
                    assert_full_match(metadata, re.escape(before_metadata))
                    succeed(f"rm {orig}", f"{'rm' if target_type == 'file' else 'rmdir'} {target}")

@test("regtest")
def _():
    def enabled(unit):
        if unit in enabled_tests:
            # The preceding tests may have restarted the unit. This only waits
            # for systemd; each check below must also wait for service readiness.
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
        machine.wait_until_succeeds(current_run_log_has_string("electrs", "serving Electrum RPC"))
        assert_full_match(get_block_height(ip('electrs'), 50001), f"{num_blocks}\n")

    if enabled("fulcrum"):
        machine.wait_until_succeeds(current_run_log_has_string("fulcrum", "listening for connections"))
        assert_full_match(get_block_height(ip('fulcrum'), 50002), f"{num_blocks}\n")

    if enabled("rbitcoin"):
        # rbitcoin syncs bitcoind's chain (its only peer) and agrees on the tip
        machine.wait_until_succeeds(
            f"[[ $(runuser -u operator -- rbitcoin-cli getblockcount) == {num_blocks} ]]"
        )
        best = succeed("runuser -u operator -- rbitcoin-cli getbestblockhash").strip().strip('"')
        assert best == succeed("bitcoin-cli getbestblockhash").strip(), best
        if test_data["rbitcoin"]["electrum"]:
            wait_for_open_port(ip("rbitcoin"), 50003)
            assert_full_match(get_block_height(ip('rbitcoin'), 50003), f"{num_blocks}\n")

    if enabled("clightning"):
        machine.wait_until_succeeds(
            f"[[ $(runuser -u operator -- lightning-cli getinfo | jq -M .blockheight) == {num_blocks} ]]"
        )

    if enabled("lnd"):
        machine.wait_until_succeeds(
            f"[[ $(runuser -u operator -- lncli getinfo | jq -M .block_height) == {num_blocks} ]]"
        )

    if enabled("btcpayserver"):
        machine.wait_until_succeeds(log_has_string("nbxplorer", f"At height: {num_blocks}"))

    if enabled("mempool"):
        assert_running("nginx")
        machine.wait_until_succeeds(
            f"[[ $(curl -fsS http://{ip('nginx')}:60845/api/v1/blocks/tip/height) == {num_blocks} ]]"
        )

# Impure: restarts lnd. Runs after `regtest`, so lnd is synced.
@test("lnd-restart-on-clean-exit")
def _():
    # `lncli stop` shuts lnd down cleanly (exit status 0), like lnd's chain
    # backend health check does when bitcoind stays unreachable. lnd must come
    # back on its own (`Restart = "always"`).
    #
    # Pause the charge-lnd timer first: charge-lnd `requires` lnd, so a timer
    # tick during this test would start lnd itself and hide a missing
    # `Restart=`. RTL only `wants` lnd and keeps running while lnd is down.
    timers = ["charge-lnd.timer"] if "charge-lnd" in enabled_tests else []
    for unit in timers:
        succeed(f"systemctl stop {unit}")
    assert_running("lnd")
    before = succeed("systemctl show -P InvocationID lnd").strip()
    succeed("runuser -u operator -- lncli stop")
    # Right after `lncli stop`, lnd may still be active (shutting down).
    # Poll for a new invocation instead of polling `is-active`.
    machine.wait_until_succeeds(f"[[ $(systemctl show -P InvocationID lnd) != '{before}' ]]")
    machine.wait_for_unit("lnd")
    machine.wait_until_succeeds("runuser -u operator -- lncli getinfo")
    for unit in timers:
        succeed(f"systemctl start {unit}")

# Impure: mines a block. Runs after `regtest`, which checks the block count.
@test("rbitcoin-mempool")
def _():
    api = f"http://{ip('nginx')}:60845/api/v1"
    num_blocks = test_data["num_blocks"]

    # Address data comes from rbitcoin's Electrum server, not its RPC.
    # Query by scripthash: mempool decodes addresses as mainnet, so a regtest
    # address would fail before reaching Electrum.
    script = succeed(
        "bitcoin-cli getblock $(bitcoin-cli getblockhash 1) 2"
        " | jq -r '.tx[0].vout[0].scriptPubKey.hex'"
    ).strip()
    scripthash = succeed(
        f"printf \"$(echo {script} | sed 's/../\\\\x&/g')\" | sha256sum | cut -d' ' -f1"
    ).strip()
    machine.wait_until_succeeds(
        f"[[ $(curl -fsS {api}/scripthash/{scripthash} | jq .chain_stats.tx_count) -ge 1 ]]"
    )

    # rbitcoin writes a new RPC cookie on every start. mempool must pick it up
    # (it re-reads COOKIE_PATH after an HTTP 401) and keep following the chain.
    succeed("systemctl restart rbitcoin")
    succeed(
        "bitcoin-cli -rpcwallet=test generatetoaddress 1"
        " $(bitcoin-cli -rpcwallet=test getnewaddress)"
    )
    machine.wait_until_succeeds(
        f"[[ $(curl -fsS {api}/blocks/tip/height) == {num_blocks + 1} ]]"
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
