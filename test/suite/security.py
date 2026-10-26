@test("security")
def test_security():
    assert_running("setup-secrets")
    # Unused secrets should be inaccessible
    assert_file_metadata("/secrets/dummy", owner="root", group="root", mode="440")

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
def test_secrets_no_argv():
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


@test("rpc-whitelist")
def test_rpc_whitelist():
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


@test("lnd-macaroons")
def test_lnd_macaroons():
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
        assert_file_metadata(macaroon, owner=user, mode="440", file_type="regular file")

    def assert_canary_untouched():
        assert_full_match(f"cat {canary}", "canary\n")
        assert_file_metadata(canary, owner="root", mode="600")
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


@test("rtl-credentials")
def test_rtl_credentials():
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
        assert_file_metadata(canary, owner="root", mode="600")
        assert_file_metadata(canary_dir, owner="root", mode="700")
        assert_full_match(f"ls -A {canary_dir}", "")

    def assert_dest_ok(dest, expected_content_cmd):
        assert_file_metadata(dest, owner=data["user"], group=data["group"],
                             mode="640", file_type="regular file")
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
        assert_file_metadata(macaroons_dir, owner=data["user"], group=data["group"], mode="770")
        succeed(f"{as_rtl} cp /dev/null {dest}", script)
        assert_dest_ok(dest, f"cat {admin_macaroon}")

        check(script, lnd["user"], admin_macaroon, dest, f"cat {admin_macaroon}")

    if cln := data["clightning"]:
        script = get_script("rtl-create-clnrest-rune-file")
        admin_rune = f"{cln['networkDir']}/admin-rune"
        check(script, cln["user"], admin_rune, f"{data_dir}/clightning-admin-rune",
              f"printf 'LIGHTNING_RUNE=\"%s\"\\n' \"$(cat {admin_rune})\"")

    succeed(f"rm -r {canary} {canary_dir}")


@test("onion-addresses")
def test_onion_addresses():
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
        assert_file_metadata(dest, owner=user, mode="600", file_type="regular file")
        assert_full_match(f"cat {dest}", re.escape(address))
        for srv, srv_user in data["serviceUsers"].items():
            path = f"{data_dir}/services/{srv}"
            assert_file_metadata(path, owner=srv_user, mode="400", file_type="regular file")
            assert_full_match(f"cat {path}", re.escape(succeed(f"cat /var/lib/tor/onion/{srv}/hostname")))

    def wait_until_finished():
        machine.wait_until_succeeds(f"test $(systemctl show -p ActiveState --value {unit}) != activating")

    canary = "/run/onion-addresses-test-canary"
    canary_dir = "/run/onion-addresses-test-canary-dir"
    succeed(f"install -m 600 <(echo canary) {canary}", f"mkdir -m 700 {canary_dir}")

    def assert_canary_untouched():
        assert_full_match(f"cat {canary}", "canary\n")
        assert_file_metadata(canary, owner="root", mode="600")
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

            assert_file_metadata(path, owner=owner, mode=str(mode), file_type="regular file")
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


# Runs before tests that stop services (backups) so that most services are running
@test("hardening-ro-paths")
def test_hardening_ro_paths():
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


# Runs after service tests: every setup-secrets run makes the secrets dir 0700
# until it succeeds, which would break services that are still starting.
@test("setup-secrets")
def test_setup_secrets():
    assert_running("setup-secrets")

    def unit_prop(prop):
        return succeed(f"systemctl show setup-secrets --value -p {prop}").strip()
    assert unit_prop("ProtectSystem") == "strict"
    assert unit_prop("PrivateNetwork") == "yes"
    assert unit_prop("NoNewPrivileges") == "yes"
    assert unit_prop("CapabilityBoundingSet") == "cap_chown cap_dac_override cap_fowner"

    # Undeclared entries whose names break unquoted, option-parsing or
    # glob-expanding shell code, a dotfile, and a symlink to a file outside
    # the secrets dir.
    unsafe = ["-x", "*", ".dotfile"]
    listing = "find /secrets -mindepth 1 -maxdepth 1 -printf '%P %u:%g %m\\n' | sort"
    before = succeed(listing)
    for name in unsafe:
        succeed(f"install -o nobody -g nogroup -m 666 /dev/null /secrets/{name!r}")
    succeed(
        "install -o nobody -g nogroup -m 644 /dev/null /run/setup-secrets-link-target",
        "ln -s /run/setup-secrets-link-target /secrets/link",
        "chown -h nobody:nogroup /secrets/link",
    )

    succeed("systemctl restart setup-secrets")

    for name in unsafe:
        assert_full_match(f"stat -c '%U:%G %a' /secrets/{name!r}", "root:root 440\n")
    assert_full_match("stat -c '%U:%G' /secrets/link", "root:root\n")
    # The link target is left alone
    assert_full_match("stat -c '%U:%G %a' /run/setup-secrets-link-target", "nobody:nogroup 644\n")

    succeed("rm -f -- /secrets/-x '/secrets/*' /secrets/.dotfile /secrets/link /run/setup-secrets-link-target")
    # Nothing else was changed
    assert succeed(listing) == before
    assert_full_match("stat -c '%U:%G %a' /secrets", "root:root 751\n")

    # A declared secret that is a symlink to a host file outside the secrets
    # dir must not get its target re-permissioned: the unit has to fail with
    # EROFS instead. /run and /dev/shm stay writable under ProtectSystem=strict
    # with the other hardening settings unless they are made read-only.
    declared = test_data["setup-secrets-declared"]
    if declared:
        secret = f"/secrets/{declared}"
        for target_dir in ["/run", "/dev/shm"]:
            target = f"{target_dir}/setup-secrets-declared-target"
            # `cp -p` keeps content and mtime, so no secret is regenerated from it
            succeed(
                f"cp -p {secret} {target}",
                f"chown nobody:nogroup {target}",
                f"chmod 644 {target}",
                f"mv {secret} /root/setup-secrets-declared-orig",
                f"ln -s {target} {secret}",
                # Repeated restarts would otherwise hit the start limit, which
                # also makes the restart fail
                "systemctl reset-failed setup-secrets",
            )
            machine.fail("systemctl restart setup-secrets")
            assert_matches("systemctl show setup-secrets --value -p Result", "^exit-code$")
            assert_full_match(f"stat -c '%U:%G %a' {target}", "nobody:nogroup 644\n")
            succeed(
                f"rm {secret} {target}",
                f"mv /root/setup-secrets-declared-orig {secret}",
                "systemctl reset-failed setup-secrets",
                "systemctl restart setup-secrets",
                "systemctl start nix-bitcoin-secrets.target",
            )
            assert succeed(listing) == before

@test("setup-secrets-supplied")
def test_setup_secrets_supplied():
    # This scenario has generateSecrets = false and supplied secret files.
    # Losing one must deny access even to the other, otherwise readable secret.
    assert_full_match("runuser -u nobody -- cat /secrets/first", "first-secret")
    assert_full_match("runuser -u nobody -- cat /secrets/second", "second-secret")
    succeed(
        "mv /secrets/second /root/setup-secrets-supplied-orig",
        "systemctl reset-failed setup-secrets",
    )
    machine.fail("systemctl restart setup-secrets")
    assert_matches("systemctl show setup-secrets --value -p Result", "^exit-code$")
    assert_matches("journalctl -b -u setup-secrets", "Secret file 'second' is missing")
    assert_full_match("stat -c '%U:%G %a' /secrets", "root:root 700\n")
    assert_full_match("stat -c '%U:%G %a' /secrets/first", "nobody:nogroup 440\n")
    machine.fail("runuser -u nobody -- cat /secrets/first")

    succeed(
        "mv /root/setup-secrets-supplied-orig /secrets/second",
        "systemctl reset-failed setup-secrets",
        "systemctl restart setup-secrets",
        "systemctl start nix-bitcoin-secrets.target",
    )
    assert_full_match("stat -c '%U:%G %a' /secrets", "root:root 751\n")
    assert_full_match("stat -c '%U:%G %a' /secrets/second", "nobody:nogroup 440\n")
    assert_full_match("runuser -u nobody -- cat /secrets/first", "first-secret")
    assert_full_match("runuser -u nobody -- cat /secrets/second", "second-secret")
