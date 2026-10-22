from collections import OrderedDict
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


# Runs before tests that stop services (backups) so that most services are running
@test("hardening-ro-paths")
def _():
    units = test_data["hardening-ro-paths"]
    assert "bitcoind" in units, f"defaultHardening services not detected: {units}"

    # Every service keeps /run and /dev read-only, also when it overrides
    # `defaultHardening` attrs
    missing = {unit: ro for unit, ro in units.items() if not {"/run", "/dev"} <= set(ro)}
    if missing:
        raise Exception(f"ReadOnlyPaths lacks /run or /dev: {missing}")

    # Check the mounts inside each running service. Root ignores file
    # permissions, so a failed write can only come from a read-only mount.
    probe = "/run/nb-ro-probe.sh"
    succeed(f"""cat > {probe} <<'EOF'
for p in /run /run/keys /dev/shm /dev/mqueue /dev/hugepages; do
  [ -d $p ] || continue
  f=$p/.nb-ro-probe
  if touch $f 2>/dev/null; then rm -f $f; echo "nb-ro-probe: writable $p"
  elif ! touch $f 2>&1 | grep -q Read-only; then echo "nb-ro-probe: unexpected error $p"; fi
done
echo "nb-ro-probe: done"
EOF""")

    def probe_results(out):
        if "nb-ro-probe: done" not in out:
            raise Exception(f"probe didn't finish: {out!r}")
        return re.findall(r"nb-ro-probe: (?:writable|unexpected error) \S+", out)

    def main_pid(unit):
        return succeed(f"systemctl show -P MainPID {unit}.service").strip()

    # Daemons: run the probe in the service's mount namespace
    def probe_daemon(unit, pid):
        try:
            return probe_results(succeed(f"nsenter -t {pid} -m -- sh {probe}"))
        except Exception:
            # The service may have restarted in between
            if main_pid(unit) == pid:
                raise
            return None

    # Active oneshot services (onion-addresses): restart with the probe as an
    # extra `ExecStartPost` and read its output from the journal
    def probe_oneshot(unit):
        dropin = f"/run/systemd/system/{unit}.service.d/nb-ro-probe.conf"
        try:
            succeed(
                f"mkdir -p {os.path.dirname(dropin)}",
                f"printf '[Service]\\nExecStartPost=/bin/sh {probe}\\n' > {dropin}",
                "systemctl daemon-reload",
                f"systemctl restart {unit}",
            )
        finally:
            succeed(f"rm -f {dropin}", "systemctl daemon-reload")
        invocation = succeed(f"systemctl show -P InvocationID {unit}.service").strip()
        journal = f"journalctl -b --output=cat _SYSTEMD_INVOCATION_ID={invocation}"
        # journald stores the probe output asynchronously
        machine.wait_until_succeeds(f"{journal} | grep -q 'nb-ro-probe: done'")
        return probe_results(succeed(journal))

    if "onion-addresses" in units:
        machine.wait_for_unit("onion-addresses")
    checked = []
    for unit in units:
        pid = main_pid(unit)
        if pid != "0":
            writable = probe_daemon(unit, pid)
        elif (succeed(f"systemctl show -P Type {unit}.service").strip() == "oneshot"
              and succeed(f"systemctl show -P ActiveState {unit}.service").strip() == "active"):
            writable = probe_oneshot(unit)
        else:
            continue
        if writable is None:
            continue
        if writable:
            raise Exception(f"{unit}: {writable}")
        checked.append(unit)
    succeed(f"rm {probe}")
    machine.log(f"hardening-ro-paths: checked {checked}")
    assert "bitcoind" in checked
    if "onion-addresses" in units:
        assert "onion-addresses" in checked

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
