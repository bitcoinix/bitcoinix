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
    # No HMAC file and no temp file is left behind
    succeed(f"[[ ! -e {hmac_file} ]]", f"! ls -d {hmac_file}.* 2>/dev/null")

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

    if "lnd-key" in files:
        key, cert = f"{gen_dir}/lnd-key", f"{gen_dir}/lnd-cert"
        key_pub = succeed(f"openssl pkey -in {key} -pubout")
        # A missing, empty or broken cert is rebuilt from the key
        for break_cert in [f"rm {cert}", f"truncate -s 0 {cert}", f"echo broken > {cert}"]:
            succeed(break_cert, generate)
            assert succeed(f"openssl x509 -in {cert} -noout -pubkey") == key_pub
        # A directory in place of the cert fails generation and stays empty
        succeed(f"rm {cert}", f"mkdir {cert}")
        machine.fail(generate)
        succeed(f"rmdir {cert}", generate)
        # An empty key, or a symlink to a missing file, fails and is kept:
        # a new key breaks clients that pinned the cert
        succeed(f"mv {key} {key}.orig")
        for break_key, kept in [(f": > {key}", f"! -s {key}"), (f"ln -s missing {key}", f"-L {key}")]:
            succeed(break_key)
            status, out = machine.execute(f"{generate} 2>&1")
            assert status != 0 and "Key file 'lnd-key' is empty or a symlink" in out, out
            succeed(f"[[ {kept} ]]", f"rm {key}")
        succeed(f"mv {key}.orig {key}")

    # A passphrase that reads as empty never goes to the backup env file
    if "backup-encryption-env" in files:
        env, passphrase = f"{gen_dir}/backup-encryption-env", f"{gen_dir}/backup-encryption-password"
        env_before = succeed(f"cat {env}")
        succeed(f"echo > {passphrase}")
        status, out = machine.execute(f"{generate} 2>&1")
        assert status != 0 and "contains no passphrase" in out, out
        assert succeed(f"cat {env}") == env_before
        succeed(f"rm {passphrase}", generate)

    # A password file with only a newline is not regenerated (it isn't empty),
    # but must not get an HMAC of the empty password either
    succeed(f"rm {hmac_file}", f"echo > {password_file}")
    status, out = machine.execute(f"{generate} 2>&1")
    assert status != 0 and "contains no password" in out, out
    succeed(f"[[ ! -e {hmac_file} ]]", f"! ls -d {hmac_file}.* 2>/dev/null")
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

    # No user may call these in the test scenarios
    unused = [
        "scantxoutset", "getblocktemplate", "fundrawtransaction", "setban", "generatetoaddress"
    ]
    # Each of these reaches only the user of the service that needs it, never `public`,
    # which electrs, fulcrum and lnd share
    granted = ["getblockfrompeer", "gettxoutsetinfo"]

    def assert_grants(user, grants):
        denied = unused + [method for method in granted if method not in grants]
        assert_rpc_access(user, ["getblockcount"] + grants, denied)

    assert_grants("public", [])
    if data["clightning"]:
        assert_grants("clightning", ["getblockfrompeer"] if data["clightning-bcli"] else [])
    if data["mempool"]:
        assert_grants("mempool", ["gettxoutsetinfo"])
    if data["btcpayserver"]:
        assert_grants("btcpayserver", ["getblockfrompeer"])


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
    # Only its user may read a macaroon. Its group may be shared, like `users`.
    for live_name, live_user in data["users"].items():
        assert_file_metadata(f"/run/lnd/{live_name}.macaroon", owner=live_user, mode="400",
                             file_type="regular file")

    def assert_macaroon_created():
        assert_file_metadata(macaroon, owner=user, mode="400", file_type="regular file")

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

    # systemd sets HOME to the lnd user's home (the lnd data dir) also for
    # the root script. Config files placed there must not be loaded.
    # A `.jq` loaded by the script's root jq fails with a syntax error.
    home = data["dataDir"]
    succeed(f"{as_lnd} sh -c 'echo \"def (\" > {home}/.jq'")
    status, output = machine.execute(f"HOME={home} {create_macaroons}")
    succeed(f"rm -f {home}/.jq")
    if status != 0:
        raise Exception(f"Creating macaroons failed with config files in HOME: '{output}'")
    assert_macaroon_created()

    # lncli prefers a default profile in $HOME/.lncli over its flags. The lnd
    # user may place one in its home, which must not redirect the script.
    home = succeed(f"getent passwd {data['user']} | cut -d: -f6").strip()
    profile = json.dumps({"default": "other", "profiles": [{
        "name": "other", "rpcserver": "127.0.0.1:1", "lnddir": "/nonexistent",
        "chain": "bitcoin", "network": "mainnet", "tlscert": "",
        "macaroons": {"default": "", "timeout": 60, "ip": "", "jar": []},
    }]})
    write_profile = f"mkdir -p {home}/.lncli && echo {shlex.quote(profile)} > {home}/.lncli/profiles.json"
    succeed(
        f"{as_lnd} sh -c {shlex.quote(write_profile)}",
        create_macaroons,
        f"rm -r {home}/.lncli",
    )
    # A crash can leave the profile file empty, which lncli can't parse
    succeed(
        f"{as_lnd} mkdir -p {home}/.lncli",
        f"{as_lnd} touch {home}/.lncli/profiles.json",
        create_macaroons,
        f"rm -r {home}/.lncli",
    )

    # Admin macaroon is a symlink to a root-only file.
    # The file must not be read and sent to lnd.
    succeed(f"{as_lnd} ln -s {canary} {network_dir}/admin.macaroon")
    status, output = machine.execute(
        "unshare --mount --propagation private sh -c"
        f" 'mount --bind {network_dir} {data['networkDir']} && {create_macaroons}'"
    )
    denied = f"{data['networkDir']}/admin.macaroon: permission denied"
    if status == 0 or denied.lower() not in output.lower():
        raise Exception(f"Unexpected result when reading the admin macaroon: {status}, '{output}'")
    assert_canary_untouched()

    # The live macaroons were never replaced
    assert_full_match(live_macaroons, re.escape(live_before))
    succeed(f"rm -r {canary} {canary_dir} {runtime_dir} {network_dir}")


def clnrest_cert_file(cln, name):
    # A scenario can set `clnrest-certs`. A relative dir starts at the network dir.
    return os.path.join(cln["networkDir"], test_data.get("clnrest-certs", ""), name)


def clnrest_status(cln, rune, method):
    # clnrest answers RPCs with 201 Created, and a rune that it refuses with 401
    return succeed(
        "curl -sS -o /dev/null -w '%{http_code}' --max-time 30 --insecure "
        f"-H @<(printf 'rune: %s\\n' {shlex.quote(rune)}) -X POST "
        f"https://{ip('clightning')}:{cln['port']}/v1/{method}"
    )


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

    def check(script, owner, src, dest, expected_content_cmd, invalid_contents=("",),
              symlink_target=canary, symlink_error="Permission denied"):
        as_owner = f"runuser -u {owner} --"

        # Destination is a symlink to a root-only file
        succeed(f"{as_rtl} ln -sfn {canary} {dest}", script)
        assert_canary_untouched()
        assert_dest_ok(dest, expected_content_cmd)

        # Source is a symlink to another file, root-only by default.
        # It must not be read and copied to the destination.
        succeed(
            f"{as_owner} mv -T {src} {src}.orig",
            f"{as_owner} ln -s {symlink_target} {src}",
        )
        status, output = machine.execute(f"{script} 2>&1")
        succeed(f"{as_owner} mv -T {src}.orig {src}")
        if status == 0 or symlink_error not in output:
            raise Exception(f"Unexpected result when reading {src}: {status}, '{output}'")
        machine.fail(f"grep -q canary {dest}")
        assert_canary_untouched()

        # Source is empty or holds another invalid credential.
        # The script must fail with a clear error and keep the current destination.
        for contents in invalid_contents:
            succeed(
                f"{as_owner} mv -T {src} {src}.orig",
                f"printf %s {shlex.quote(contents)} | {as_owner} tee {src} >/dev/null",
            )
            status, output = machine.execute(f"{script} 2>&1")
            succeed(f"{as_owner} mv -T {src}.orig {src}")
            if status == 0 or f"Error: '{src}' is empty" not in output:
                raise Exception(f"Unexpected result when reading {src} with {contents!r}: {status}, '{output}'")
            assert_dest_ok(dest, expected_content_cmd)

        succeed(script)
        assert_dest_ok(dest, expected_content_cmd)

    def check_rune(script, cln):
        # RTL's rune is created once and kept in clightning's network dir.
        # A start creates a new one when the file holds no rune that clightning
        # stored with RTL's restrictions. It revokes all other runes with RTL's
        # marker, but no other rune.
        as_cln = f"runuser -u {cln['user']} --"
        src = f"{cln['networkDir']}/rtl-rune"
        dest = f"{data_dir}/clightning-admin-rune"
        marker = "bitcoinix-rtl#"
        # The unique IDs of the valid runes with the marker
        rtl_runes = ("lightning-cli showrunes | jq -c --arg marker " + shlex.quote(marker) +
                     " '[.runes[] | select((.blacklisted | not) and any(.restrictions[];"
                     " [.alternatives[] | .fieldname + .condition + .value] == [$marker]))"
                     " | .unique_id]'")

        def show(rune):
            return succeed_json(f"lightning-cli -k showrunes rune={shlex.quote(rune)}")["runes"][0]

        def create(restrictions, rune=None):
            args = f"rune={shlex.quote(rune)} " if rune else ""
            return succeed_json(f"lightning-cli -k createrune {args}"
                                f"restrictions={shlex.quote(json.dumps(restrictions))}")["rune"]

        def set_src(contents):
            # With the mode of the files that the script creates
            succeed(f"printf %s {shlex.quote(contents)} | {as_cln} bash -c 'umask 077; cat > {src}.test'",
                    f"{as_cln} mv -fT {src}.test {src}")

        def run_script():
            succeed(script)
            assert_file_metadata(src, owner=cln["user"], mode="600", file_type="regular file")
            rune = succeed(f"cat {src}").rstrip("\n")
            assert_dest_ok(dest, f"printf 'LIGHTNING_RUNE=\"%s\"\\n' {shlex.quote(rune)}")
            # It's the only valid rune with RTL's marker
            assert succeed_json(rtl_runes) == [show(rune)["unique_id"]], rune
            return rune

        rune = succeed(f"cat {src}").rstrip("\n")
        count_runes = "lightning-cli showrunes | jq '.runes | length'"
        runes = succeed(count_runes)
        assert run_script() == rune, "A start replaced RTL's rune"
        assert succeed(count_runes) == runes, "A start created another rune"

        # Earlier versions copied the admin rune to RTL. Without one
        # (`createAdminRune = false`), use a rune without restrictions instead.
        if cln["createAdminRune"]:
            admin_rune = succeed(f"cat {cln['networkDir']}/admin-rune").rstrip("\n")
        else:
            admin_rune = succeed_json("lightning-cli createrune")["rune"]
        succeed(f"printf 'LIGHTNING_RUNE=\"%s\"\\n' {shlex.quote(admin_rune)} | {as_rtl} tee {dest} >/dev/null")
        assert run_script() == rune

        # Destination is a symlink to a root-only file
        succeed(f"{as_rtl} ln -sfn {canary} {dest}")
        assert run_script() == rune
        assert_canary_untouched()

        # Each of these gets a new rune, and the start revokes the one before
        succeed(f"{as_cln} ln -sfn {canary} {src}")
        previous = run_script()
        machine.fail(f"grep -q canary {src} {dest}")
        assert_canary_untouched()
        foreign = [
            # The admin rune, a rune derived from it and another app's rune.
            # They don't have the marker and must not be revoked.
            admin_rune,
            create([["method=getinfo"]], rune=admin_rune),
            create([["method=getinfo"]]),
        ]
        for contents in ("", "null\n", "not-a-rune\n", *(f"{r}\n" for r in foreign)):
            with machine.nested(f"rune file contents: {contents!r}"):
                set_src(contents)
                new = run_script()
                assert new not in (previous, contents.rstrip("\n"))
                assert show(previous).get("blacklisted"), previous
                previous = new
        for r in foreign:
            assert not show(r).get("blacklisted"), f"A rune without RTL's marker was revoked: {r}"

        # An earlier RTL rune with other restrictions, and one that a lost file
        # left behind
        earlier = create([["method=getinfo"], [marker]])
        lost = create([["method=getinfo"], [marker]])
        set_src(f"{earlier}\n")
        new = run_script()
        for r in (previous, earlier, lost):
            assert show(r).get("blacklisted"), r
        previous = new

        # A rune that was revoked by hand, for example after a leak
        unique_id = show(previous)["unique_id"]
        succeed(f"lightning-cli blacklistrune {unique_id} {unique_id}")
        new = run_script()
        assert new != previous
        previous = new

        # clightning gives a new rune the next unique ID, also when it's blacklisted.
        # RTL's rune is the last one created, so its ID comes right before the next IDs.
        # Revoke it and the next two IDs, then restart RTL.
        unique_id = int(show(previous)["unique_id"])
        succeed(f"lightning-cli blacklistrune {unique_id} {unique_id + 2}", "systemctl restart rtl")
        new = succeed(f"cat {src}").rstrip("\n")
        info = show(new)
        assert not info.get("blacklisted") and int(info["unique_id"]) == unique_id + 3, info
        assert clnrest_status(cln, new, "getinfo") == "201"
        assert run_script() == new
        previous = new

        # After 10 new runes with blacklisted IDs, the start fails and keeps the files.
        # It still revokes an earlier RTL rune. The next start tries the next IDs.
        unique_id = int(show(previous)["unique_id"])
        earlier = create([["method=getinfo"], [marker]])
        assert int(show(earlier)["unique_id"]) == unique_id + 1
        succeed(f"lightning-cli blacklistrune {unique_id} {unique_id}",
                f"lightning-cli blacklistrune {unique_id + 2} {unique_id + 11}")
        status, output = machine.execute(f"{script} 2>&1")
        assert status != 0 and f"up to {unique_id + 11}, are blacklisted" in output, (status, output)
        assert show(earlier).get("blacklisted"), earlier
        assert succeed(f"cat {src}").rstrip("\n") == previous
        assert_dest_ok(dest, f"printf 'LIGHTNING_RUNE=\"%s\"\\n' {shlex.quote(previous)}")
        assert int(show(run_script())["unique_id"]) == unique_id + 12

        # Start RTL with its new rune. RTL reads the rune only when it starts.
        succeed("systemctl restart rtl")
        assert_running("rtl")
        machine.wait_until_succeeds(current_run_log_has_string("rtl", "Server is up and running"))

    if lnd := data["lnd"]:
        script = get_script("rtl-copy-macaroon")
        macaroon = "/run/lnd/rtl.macaroon"
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
        assert_dest_ok(dest, f"cat {macaroon}")

        # Earlier versions copied the admin macaroon to RTL
        succeed(f"{as_rtl} tee {dest} < {lnd['networkDir']}/admin.macaroon >/dev/null", script)
        assert_dest_ok(dest, f"cat {macaroon}")

        # The lnd user can write the source dir, `/run/lnd`. A symlink there to a
        # file of the rtl user must not make RTL send this file to lnd.
        rtl_canary = "/run/rtl-test-rtl-canary"
        succeed(f"install -m 600 -o {data['user']} <(echo rtl-canary) {rtl_canary}")
        check(script, lnd["user"], macaroon, dest, f"cat {macaroon}",
              symlink_target=rtl_canary, symlink_error="Too many levels of symbolic links")
        succeed(f"rm {rtl_canary}")

    if cln := data["clightning"]:
        script = get_script("rtl-create-clnrest-rune-file")
        check_rune(script, cln)
        cert = clnrest_cert_file(cln, "server.pem")
        check(script, cln["user"], cert, f"{data_dir}/clnrest-cert.pem", f"cat {cert}")

    succeed(f"rm -r {canary} {canary_dir}")


@test("rtl-backend-certs")
def test_rtl_backend_certs():
    # RTL sends the lnd macaroon and the clightning rune with
    # `rejectUnauthorized: false`. With its preload, a connection to a backend
    # must present the backend's pinned cert, and every other connection gets the
    # normal checks against the system CAs. Run RTL's own HTTP client like RTL:
    # as its user, with its environment.
    assert_running("rtl")
    pid = succeed("systemctl show -P MainPID rtl").strip()
    # `bin/rtl` runs `node <rtl>/rtl.js`
    node, rtl_js = succeed(f"tr '\\0' ' ' < /proc/{pid}/cmdline").split()[:2]
    request_js = f"{os.path.dirname(rtl_js)}/backend/utils/request.js"
    env = shlex.split(succeed("systemctl show -P Environment rtl"))
    pins_file = next(var.split("=", 1)[1] for var in env if var.startswith("RTL_BACKEND_CERTS="))
    pins = succeed_json(f"cat {pins_file}")
    # Each backend URL in RTL's config has a pin. RTL renames `Settings` when it starts.
    conf = f"{test_data['rtl-credentials']['dataDir']}/RTL-Config.json"
    urls = succeed(f"jq -r '.nodes[] | (.settings // .Settings).lnServerUrl' {conf}").split()
    assert sorted(urls) == sorted(pins), (urls, pins)

    def rtl_node(args, extra_env=""):
        return (f"timeout 20 runuser -u {test_data['rtl-credentials']['user']} --"
                f" env {shlex.join(env)} {extra_env} {node} {args}")

    # Sends a GET with RTL's HTTP client, as RTL does for its backends.
    # Prints `ok`, the HTTP error status or the error code.
    get = ("const { default: request } = await import(process.argv[1]);"
           "await request.get({ url: process.argv[2], rejectUnauthorized: false, json: true,"
           " headers: { 'Grpc-Metadata-macaroon': '00' } })"
           ".then(() => console.log('ok'),"
           " (error) => console.log(error.statusCode ?? error.error.code));"
           "process.exit();")

    def rtl_get(url, extra_env=""):
        args = f"--input-type=module -e {shlex.quote(get)} {request_js} {url}"
        return succeed(rtl_node(args, extra_env)).strip()

    cert_error = r"[A-Z_]*(CERT|SIGNATURE)[A-Z_]*"

    # A TLS server with a throwaway cert. It logs the request bytes it receives
    # and each closed connection. No `$`: systemd-run would expand it.
    # With clightning, clnrest's own CA issues the cert. A pin of that CA instead
    # of clnrest's server cert would let it pass.
    fake = "/run/rtl-test-fake-backend"
    fake_port = 7443
    fake_url = f"https://127.0.0.1:{fake_port}"
    server = ("const fs = require('fs'); const [dir, port] = process.argv.slice(1);"
              "require('tls').createServer("
              " { key: fs.readFileSync(dir + '/key'), cert: fs.readFileSync(dir + '/cert') },"
              " (socket) => socket.on('data', (data) => {"
              " fs.appendFileSync(dir + '/received', data);"
              " socket.end('HTTP/1.1 200 OK\\r\\nContent-Length: 0\\r\\n\\r\\n'); }))"
              ".on('connection', (tcp) => tcp.on('close',"
              " () => fs.appendFileSync(dir + '/closed', '\\n')))"
              ".listen(port, '127.0.0.1')")
    cln = test_data["rtl-credentials"]["clightning"]
    issuer_ca = clnrest_cert_file(cln, "ca.pem") if cln else ""
    issuer_key = clnrest_cert_file(cln, "ca-key.pem") if cln else ""
    issuer = f" -CA {issuer_ca} -CAkey {issuer_key}" if cln else ""
    succeed(
        f"mkdir {fake}",
        "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1"
        f" -subj /CN=localhost -addext subjectAltName=IP:127.0.0.1{issuer}"
        f" -keyout {fake}/key -out {fake}/cert 2>/dev/null",
        f"systemd-run --unit=rtl-test-fake-backend {node} -e {shlex.quote(server)} {fake} {fake_port}",
    )
    wait_for_open_port("127.0.0.1", fake_port)

    def fake_get(pins=None, extra_env=""):
        """Returns the result and the request bytes that the fake server received"""
        if pins:
            succeed(f"echo {shlex.quote(json.dumps(pins))} > {fake}/pins")
            extra_env += f" RTL_BACKEND_CERTS={fake}/pins"
        succeed(f"rm -f {fake}/received {fake}/closed")
        result = rtl_get(fake_url, extra_env)
        machine.wait_until_succeeds(f"[[ -s {fake}/closed ]]")
        return result, succeed(f"cat {fake}/received 2>/dev/null || true")

    # With its own cert pinned, the fake server gets the request
    result, received = fake_get({fake_url: f"{fake}/cert"})
    assert result == "ok" and received.startswith("GET / "), (result, received)
    # A server that isn't a backend must have a cert from a system CA
    result, received = fake_get()
    assert re.fullmatch(cert_error, result) and received == "", (result, received)
    # NODE_EXTRA_CA_CERTS adds its cert and issuer. The cert names the server's IP.
    succeed(f"cat {fake}/cert {issuer_ca} > {fake}/extra-cas")
    result, received = fake_get(extra_env=f"NODE_EXTRA_CA_CERTS={fake}/extra-cas")
    assert result == "ok" and received.startswith("GET / "), (result, received)

    for url, cert in pins.items():
        with machine.nested(f"backend: {url}"):
            # The backend itself passes. Its answer to the fake credential doesn't matter.
            assert_str_matches(rtl_get(url), r"^(ok|\d{3})$")
            # Another spelling of the backend's address has no pin, so the backend's
            # cert fails the system CAs. Before, RTL sent the credential this way.
            parsed = urlparse(url)
            alias = f"https://[::ffff:{parsed.hostname}]:{parsed.port}"
            assert re.fullmatch(cert_error, rtl_get(alias)), alias
            # A server on the backend's address with another cert gets nothing.
            # Only the first cert in a pin file counts.
            succeed(f"cat {cert} {fake}/cert > {fake}/certs")
            result, received = fake_get({fake_url: f"{fake}/certs"})
            assert re.fullmatch(cert_error, result) and received == "", (result, received)

    # RTL doesn't start without valid pins, or with a backend URL from its
    # environment, which may even use plain HTTP
    bad_pins = {
        "empty": {fake_url: f"{fake}/empty"},
        "http": {"http://127.0.0.1:8080": f"{fake}/cert"},
    }
    succeed(f"touch {fake}/empty", *(
        f"echo {shlex.quote(json.dumps(content))} > {fake}/{name}.json"
        for name, content in bad_pins.items()
    ))
    for bad_env, error in [("RTL_BACKEND_CERTS=", "RTL_BACKEND_CERTS is not set"),
                           (f"RTL_BACKEND_CERTS={fake}/empty.json", "holds no PEM certificate"),
                           (f"RTL_BACKEND_CERTS={fake}/http.json", "isn't an HTTPS URL"),
                           ("LN_SERVER_URL=http://127.0.0.1:18080", "LN_SERVER_URL is set"),
                           ("LND_SERVER_URL=http://127.0.0.1:18080", "LND_SERVER_URL is set")]:
        status, output = machine.execute(f"{rtl_node('-e 0', bad_env)} 2>&1")
        assert status != 0 and error in output, output

    succeed("systemctl stop rtl-test-fake-backend", f"rm -r {fake}")


# The lnd RPCs that RTL calls: the RPCs of the lnd REST routes in RTL's
# `backend/controllers/lnd`
RTL_LND_RPCS = [f"/lnrpc.Lightning/{rpc}" for rpc in (
    "AddInvoice", "ClosedChannels", "CloseChannel", "ConnectPeer", "DecodePayReq",
    "DescribeGraph", "DisconnectPeer", "ExportAllChannelBackups", "ExportChannelBackup",
    "FeeReport", "ForwardingHistory", "GetChanInfo", "GetInfo", "GetNetworkInfo",
    "GetNodeInfo", "GetTransactions", "ListChannels", "ListInvoices", "ListPayments",
    "ListPeers", "NewAddress", "OpenChannelSync", "PendingChannels", "QueryRoutes",
    "RestoreChannelBackups", "SendCoins", "SignMessage", "UpdateChannelPolicy",
    "VerifyChanBackup", "VerifyMessage", "WalletBalance",
)] + [
    "/invoicesrpc.Invoices/LookupInvoiceV2",
    "/invoicesrpc.Invoices/SubscribeSingleInvoice",
    "/routerrpc.Router/SendPaymentV2",
    "/routerrpc.Router/TrackPaymentV2",
] + [f"/walletrpc.WalletKit/{rpc}" for rpc in (
    "BumpFee", "LabelTransaction", "LeaseOutput", "ListUnspent", "ReleaseOutput",
)]

# The clightning methods that RTL calls, from `backend/controllers/cln` in RTL's source.
# clnrest checks `listclnrest-notifications` for RTL's websocket.
RTL_CLN_METHODS = (
    "autoclean-once", "checkmessage", "close", "connect", "decode", "disableoffer",
    "disconnect", "feerates", "fetchinvoice", "fundchannel", "funderupdate", "getinfo",
    "getroute", "invoice", "keysend", "listchannels", "listclnrest-notifications",
    "listconfigs", "listforwards", "listfunds", "listinvoices", "listnodes", "listoffers",
    "listpeerchannels", "listpeers", "listsendpays", "newaddr", "offer", "pay",
    "setchannel", "signmessage", "withdraw",
)


@test("rtl-permissions")
def test_rtl_permissions():
    # RTL gets an lnd macaroon and a clightning rune with only the permissions
    # that its features use. Check RTL's copies.
    assert_running("rtl")
    data = test_data["rtl-credentials"]
    data_dir = data["dataDir"]

    if lnd := data["lnd"]:
        # A scenario can build lnd without some of its gRPC services. lnd then lacks
        # their RPCs, and RTL's macaroon lacks their permissions.
        missing_services = test_data.get("lnd-missing-services", [])
        missing = [rpc for rpc in RTL_LND_RPCS if rpc.split("/")[1] in missing_services]
        rpcs = [rpc for rpc in RTL_LND_RPCS if rpc not in missing]
        # lnd's start warns about each of them
        log = succeed("journalctl -b -o cat -u lnd")
        warned = set(re.findall(r"Macaroon rtl doesn't get optional permission uri:(\S+),", log))
        assert warned == set(missing), warned

        lncli = "runuser -u operator -- lncli"
        # Readable by the lncli wrapper, which runs as the lnd user
        macaroon = "/run/rtl-permissions-test.macaroon"
        succeed(f"install -m 400 -o {lnd['user']} {data_dir}/macaroons/admin.macaroon {macaroon}")
        # This --macaroonpath overrides the admin macaroon of the lncli wrapper
        succeed(f"{lncli} --macaroonpath {macaroon} getinfo")
        # It has a `uri` permission for each of these RPCs, and no other permission
        permissions = succeed_json(f"{lncli} printmacaroon --macaroon_file {macaroon}")["permissions"]
        assert sorted(permissions) == sorted(f"uri:{rpc}" for rpc in rpcs), permissions
        status, output = machine.execute(f"{lncli} --macaroonpath {macaroon} bakemacaroon info:read 2>&1")
        assert status != 0 and "permission denied" in output, (status, output)

        def has_permissions(rpc):
            # lnd checks the macaroon for the RPC's permissions. The admin macaroon
            # authenticates the check.
            body = (f"base64 -w0 {macaroon} | jq -Rs --arg rpc {rpc} "
                    "'{macaroon: ., fullMethod: $rpc, check_default_perms_from_full_method: true}'")
            curl = ("curl -sS --max-time 30 --cacert /secrets/lnd-cert "
                    "-H @<(printf 'Grpc-Metadata-macaroon: %s\\n' "
                    f"\"$(xxd -ps -c 99999 {lnd['networkDir']}/admin.macaroon)\") --data-binary @- "
                    f"https://{ip('lnd')}:{lnd['restPort']}/v1/macaroon/checkpermissions")
            return succeed_json(f"{body} | runuser -u {lnd['user']} -- bash -c {shlex.quote(curl)}")

        for rpc in rpcs:
            response = has_permissions(rpc)
            assert response.get("valid") is True, (rpc, response)
        # lnd answers an unknown RPC with another error
        for rpc in ("/lnrpc.Lightning/BakeMacaroon", "/lnrpc.Lightning/StopDaemon",
                    "/lnrpc.Lightning/DeleteAllPayments", "/signrpc.Signer/SignOutputRaw"):
            response = has_permissions(rpc)
            assert response.get("message") == "permission denied", (rpc, response)
        succeed(f"rm {macaroon}")

    if cln := data["clightning"]:
        rune = succeed(
            f"sed -n 's/^LIGHTNING_RUNE=\"\\(.*\\)\"$/\\1/p' {data_dir}/clightning-admin-rune"
        ).rstrip("\n")

        assert clnrest_status(cln, rune, "getinfo") == "201"
        # A method that RTL doesn't call
        assert clnrest_status(cln, rune, "createrune") == "401"

        def checkrune(method):
            return f"lightning-cli -k checkrune rune={shlex.quote(rune)} method={method}"

        for method in RTL_CLN_METHODS:
            succeed(f"{checkrune(method)} | jq -e .valid")
        for method in ("createrune", "blacklistrune", "showrunes", "stop"):
            assert_matches(f"{checkrune(method)} 2>&1 || true", "Not permitted")

    # After login, RTL's dashboard loads these for each backend. A missing lnd
    # permission or clightning method for one of these requests fails it.
    dashboard = {
        "lnd": [("GET", path, None) for path in (
            "getinfo", "balance", "channels", "channels/pending", "channels/closed", "peers",
            "network/info", "fees", "payments?max_payments=100000&reversed=true",
            "invoices?num_max_invoices=10&index_offset=0&reversed=true",
        )],
        "cln": [
            ("GET", "getinfo", None), ("POST", "invoices/lookup", {}),
            ("GET", "channels/listPeerChannels", None), ("GET", "onchain/utxos", None),
            ("POST", "network/feeRates", {"style": "perkw"}),
            ("POST", "network/feeRates", {"style": "perkb"}),
            ("GET", "peers", None), ("GET", "payments", None),
        ],
    }
    # Node indices from `modules/rtl.nix`
    nodes = {"cln": (1, data["clightning"]), "lnd": (2, data["lnd"])}
    rtl = f"http://{ip('rtl')}:{data['port']}/rtl"
    jar = "/run/rtl-permissions-test-cookies"
    # The first page sets the session and CSRF cookies
    succeed(f"curl -fsS -o /dev/null -c {jar} {rtl}/")
    xsrf = unquote(succeed(f"awk '$6 == \"XSRF-TOKEN\" {{ print $7 }}' {jar}").strip())
    token = None

    def api(method, path, body=None):
        headers = [f"X-XSRF-TOKEN: {xsrf}"] + ([f"Authorization: Bearer {token}"] if token else [])
        args = " ".join(f"-H {shlex.quote(header)}" for header in headers)
        if body is not None:
            args += f" -H 'Content-Type: application/json' --data-binary {shlex.quote(json.dumps(body))}"
        output = succeed(f"curl -sS --max-time 60 -b {jar} -c {jar} {args} -X {method} "
                         f"-w '\\n%{{http_code}}' {shlex.quote(f'{rtl}/api/{path}')}")
        response, status = output.rsplit("\n", 1)
        return status, response

    password = succeed("cat /secrets/rtl-password").rstrip("\n")
    status, response = api("POST", "authenticate", {
        "authenticateWith": "PASSWORD",
        "authenticationValue": hashlib.sha256(password.encode()).hexdigest(),
    })
    assert status == "200", (status, response)
    token = json.loads(response)["token"]
    for backend, (index, enabled) in nodes.items():
        if not enabled:
            continue
        with machine.nested(f"RTL dashboard: {backend}"):
            status, response = api("GET", f"conf/updateSelNode/{index}/-1")
            assert status == "200", (status, response)
            for method, path, body in dashboard[backend]:
                status, response = api(method, f"{backend}/{path}", body)
                assert status == "200", (backend, path, status, response)
    succeed(f"rm {jar}")


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
        assert_file_metadata(f"/secrets/{name}", owner="root", group="root", mode="440")
    assert_file_metadata("/secrets/link", owner="root", group="root")
    # The link target is left alone
    assert_file_metadata("/run/setup-secrets-link-target", owner="nobody", group="nogroup", mode="644")

    succeed("rm -f -- /secrets/-x '/secrets/*' /secrets/.dotfile /secrets/link /run/setup-secrets-link-target")
    # Nothing else was changed
    assert succeed(listing) == before
    assert_file_metadata("/secrets", owner="root", group="root", mode="751")

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
            assert_file_metadata(target, owner="nobody", group="nogroup", mode="644")
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
    # An empty one must too: services would get an empty credential.
    assert_full_match("runuser -u nobody -- cat /secrets/first", "first-secret")
    assert_full_match("runuser -u nobody -- cat /secrets/second", "second-secret")
    # Declared with `allowEmpty`
    assert_file_metadata("/secrets/empty", owner="nobody", group="nogroup", mode="440")
    orig = "/root/setup-secrets-supplied-orig"
    for problem, break_secret in [
        ("missing", f"mv /secrets/second {orig}"),
        ("not a regular file", f"mv /secrets/second {orig} && mkdir /secrets/second"),
        ("empty", f"cp -p /secrets/second {orig} && truncate -s 0 /secrets/second"),
    ]:
        succeed(break_secret, "systemctl reset-failed setup-secrets")
        machine.fail("systemctl restart setup-secrets")
        assert_matches("systemctl show setup-secrets --value -p Result", "^exit-code$")
        assert_matches("journalctl -b -u setup-secrets", f"Secret file 'second' is {problem}")
        assert_file_metadata("/secrets", owner="root", group="root", mode="700")
        assert_file_metadata("/secrets/first", owner="nobody", group="nogroup", mode="440")
        machine.fail("runuser -u nobody -- cat /secrets/first")

        succeed(
            f"rm -rf /secrets/second && mv {orig} /secrets/second",
            "systemctl reset-failed setup-secrets",
            "systemctl restart setup-secrets",
            "systemctl start nix-bitcoin-secrets.target",
        )
        assert_file_metadata("/secrets", owner="root", group="root", mode="751")
        assert_file_metadata("/secrets/second", owner="nobody", group="nogroup", mode="440")
        assert_full_match("runuser -u nobody -- cat /secrets/first", "first-secret")
        assert_full_match("runuser -u nobody -- cat /secrets/second", "second-secret")
