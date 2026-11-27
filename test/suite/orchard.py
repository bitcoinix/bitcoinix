@test("orchard")
def test_orchard():
    data = test_data["orchard"]
    url = f"http://{ip('orchard')}:{data['port']}"
    mint_url = f"http://{ip('cdk-mintd')}:{data['mintPort']}/v1"
    assert_running("orchard")
    machine.wait_until_succeeds(f"curl -fsS {url}/config.json")
    runtime = succeed_json(f"curl -fsS {url}/config.json")
    assert runtime["mint"]["enabled"]
    assert not runtime["mode"]["dev_auth_bypass"]
    assert "<html" in succeed(f"curl -fsS {url}/")

    def graphql(query, token=None):
        auth = f"-H 'Authorization: Bearer {token}'" if token else ""
        return succeed_json(
            f"curl -fsS -H 'Content-Type: application/json' {auth} "
            f"--data {shlex.quote(json.dumps({'query': query}))} {url}/api"
        )

    def query_ok(query, token=None):
        result = graphql(query, token)
        assert not result.get("errors"), result
        return result["data"]

    def login():
        return query_ok('mutation { auth_authentication(authentication: {name: "admin", password: "test-password-long"}) { access_token } }')["auth_authentication"]["access_token"]

    # Public setup status is allowed; mint data and changes require login.
    assert "errors" in graphql('{ mint_info_rpc { name } }')
    assert "errors" in graphql('mutation { auth_initialize(initialize: {key: "wrong", name: "admin", password: "test-password-long"}) { access_token } }')
    setup_key = succeed(f"cat {data['setupKeyFile']}").strip()
    token = query_ok(
        'mutation { auth_initialize(initialize: {key: ' + json.dumps(setup_key)
        + ', name: "admin", password: "test-password-long"}) { access_token } }'
    )["auth_initialize"]["access_token"]
    result = query_ok('{ mint_info { name } mint_info_rpc { name } mint_balances { keyset balance } mint_keysets { id } }', token)
    assert result["mint_info"]["name"] == "Bitcoinix test mint", result
    assert result["mint_info_rpc"]["name"] == "Bitcoinix test mint", result
    assert result["mint_balances"] == [], result
    assert result["mint_keysets"], result
    query_ok('mutation { mint_name_update(name: "Orchard test mint") { name } }', token)
    machine.wait_until_succeeds(f"curl -fsS {mint_url}/info | jq -e '.name == \"Orchard test mint\"'")

    # The service's supplementary group grants only read access to the live
    # mint DB/WAL/SHM. Neither signing secrets nor the mint directory are shared.
    as_orchard = f"setpriv --reuid={data['user']} --regid={data['group']} --groups=orchard-mint --"
    database = f"{data['mintDataDir']}/cdk-mintd.sqlite"
    for suffix in ["", "-wal", "-shm"]:
        succeed(f"{as_orchard} test -r {database}{suffix}")
        machine.fail(f"{as_orchard} test -w {database}{suffix}")
    backend_secret = (
        "/run/cdk-mintd/lnd.macaroon"
        if data["mintBackend"] == "lnd"
        else f"{data['clnNetworkDir']}/lightning-rpc"
    )
    for path in [data["seedFile"], f"{data['rpcTlsDir']}/server/server.key", backend_secret]:
        succeed(f"test -e {path}")
        machine.fail(f"{as_orchard} test -r {path}")
    machine.fail(f"find {data['rpcTlsDir']} -name 'ca.key' | grep .")
    machine.fail(f"{as_orchard} test -w {data['mintDataDir']}")
    machine.fail(f"runuser -u nobody -- cat {data['setupKeyFile']}")
    # Check the same RPC with and without credentials, so proto parsing or an
    # unavailable listener cannot make the authentication test pass spuriously.
    rpc = (f"grpcurl -H 'x-cdk-protocol-version: 1.0.0' -connect-timeout 3 -max-time 5 -cacert {data['rpcTlsDir']}/client/ca.pem "
           f"-import-path {os.path.dirname(data['proto'])} -proto {os.path.basename(data['proto'])}")
    method = f"{data['rpcAddress']}:{data['mintRpcPort']} cdk_mint_management_v1.CdkMint/GetInfo"
    rpc_info = succeed_json(
        f"{rpc} -cert {data['rpcTlsDir']}/client/client.pem "
        f"-key {data['rpcTlsDir']}/client/client.key {method}"
    )
    assert rpc_info["name"] == "Orchard test mint", rpc_info
    machine.fail(f"{rpc} {method}")
    crypto_key = succeed(f"sha256sum {data['dataDir']}/crypto.key")
    succeed("systemctl stop cdk-mintd")
    machine.wait_until_succeeds("test $(systemctl is-active orchard) = inactive")
    # Mint maintenance must not let another user replace the login/setup page.
    status, out = machine.execute(
        f"runuser -u nobody -- timeout 3 nc -l {ip('orchard')} {data['port']} 2>&1"
    )
    assert re.search("Address already in use|Cannot assign requested address", out), \
        f"An unprivileged user took Orchard's port (status {status}): {out!r}"
    machine.fail(f"curl -sS --max-time 3 {url}/")
    if "netns-isolation" not in enabled_tests:
        assert_matches(f"ss -Htlnp 'sport = :{data['port']}'", r'\("systemd",pid=1,')
        machine.fail("test -e /run/orchard/orchard.sock")
    succeed("systemctl start cdk-mintd")
    machine.wait_for_unit("orchard")
    machine.wait_until_succeeds(f"curl -fsS {url}/config.json")
    assert succeed(f"sha256sum {data['dataDir']}/crypto.key") == crypto_key
    # Accounts persist but JWTs deliberately don't survive an Orchard restart.
    token = login()
    result = query_ok('{ mint_info_rpc { name } mint_balances { keyset balance } mint_keysets { id } }', token)
    assert result["mint_info_rpc"]["name"] == "Orchard test mint", result
    assert result["mint_balances"] == [], result
    assert result["mint_keysets"], result
    query_ok('mutation { mint_name_update(name: "Bitcoinix test mint") { name } }', token)

    # A live tmpfiles run must preserve access without restarting either service
    # or invalidating the login session. Repeat to catch an existing masked ACL.
    mint_invocation = succeed("systemctl show -P InvocationID cdk-mintd")
    orchard_invocation = succeed("systemctl show -P InvocationID orchard")
    mint_directory_rule = next(
        line for line in succeed("systemd-tmpfiles --cat-config").splitlines()
        if line.startswith("d ") and shlex.split(line)[1] == data["mintDataDir"]
    )
    for _ in range(2):
        # Run the actual directory rule alone to observe the interval before
        # tmpfiles reaches its glob-capable rules (including the ACL repair).
        succeed(f"printf '%s\\n' {shlex.quote(mint_directory_rule)} | systemd-tmpfiles --create -")
        assert query_ok('{ mint_keysets { id } }', token)["mint_keysets"]
        succeed(f"systemd-tmpfiles --create --prefix={data['mintDataDir']}")
        assert query_ok('{ mint_keysets { id } }', token)["mint_keysets"]
        assert succeed("systemctl show -P InvocationID cdk-mintd") == mint_invocation
        assert succeed("systemctl show -P InvocationID orchard") == orchard_invocation
        succeed(f"{as_orchard} test -x {data['mintDataDir']}")
        machine.fail(f"{as_orchard} test -r {data['mintDataDir']}")
        machine.fail(f"{as_orchard} test -w {data['mintDataDir']}")
        for suffix in ["", "-wal", "-shm"]:
            succeed(f"{as_orchard} test -r {database}{suffix}")
            machine.fail(f"{as_orchard} test -w {database}{suffix}")

    # Dormant ACL entries must not regain read or write access. Check both
    # startup and tmpfiles, which must replace rather than merge access ACLs.
    database_files = [f"{database}{suffix}" for suffix in ["", "-wal", "-shm"]]
    files = " ".join(database_files)
    as_nobody = "runuser -u nobody --"
    original_acls = succeed(f"getfacl -p {data['mintDataDir']} {files}")
    succeed("systemctl stop orchard")
    succeed(f"setfacl -m u:nobody:rwx,m::--- {data['mintDataDir']}")
    succeed(f"setfacl -m u:nobody:rw-,m::--- {files}")
    try:
        for _ in range(2):
            succeed("systemctl restart orchard")
            machine.wait_until_succeeds(f"curl -fsS {url}/config.json")
            token = login()
            assert query_ok('{ mint_keysets { id } }', token)["mint_keysets"]
            assert_matches(f"getfacl -cp {data['mintDataDir']}", r"(?m)^mask::--x$")
            machine.fail(f"{as_nobody} test -x {data['mintDataDir']}")
            machine.fail(f"{as_nobody} test -r {data['mintDataDir']}")
            machine.fail(f"{as_nobody} test -w {data['mintDataDir']}")
            for path in database_files:
                assert_matches(f"getfacl -cp {path}", r"(?m)^mask::r--$")
                # Check removal on the files too, independently of traversal.
                assert "user:nobody:" not in succeed(f"getfacl -cp {path}")
                machine.fail(f"{as_nobody} test -r {path}")
                machine.fail(f"{as_nobody} test -w {path}")
            assert succeed("systemctl show -P InvocationID cdk-mintd") == mint_invocation
            # Reintroduce a masked directory entry while Orchard is running.
            # Tmpfiles must not revive it while restoring Orchard's access.
            succeed(f"setfacl -m u:nobody:rwx,m::--- {data['mintDataDir']}")
            succeed(f"systemd-tmpfiles --create --prefix={data['mintDataDir']}")
            machine.fail(f"{as_nobody} test -x {data['mintDataDir']}")
            assert "user:nobody:" not in succeed(f"getfacl -cp {data['mintDataDir']}")
            for path in database_files:
                machine.fail(f"{as_nobody} test -r {path}")
            assert query_ok('{ mint_keysets { id } }', token)["mint_keysets"]
    finally:
        succeed(f"printf '%s' {shlex.quote(original_acls)} | setfacl --restore=-")

    # Force setfacl to fail by changing ownership of the live DB. This also
    # checks that the grant runs as the mint user, without root's override.
    # The mint keeps its open database handles throughout the Orchard failure.
    succeed("systemctl stop orchard")
    database_owner = succeed(f"stat -c '%u:%g' {database}").strip()
    try:
        # setfacl skips writes for an ACL that already matches.
        succeed(f"setfacl -b {database}")
        succeed(f"chown root:root {database}")
        machine.fail("systemctl start orchard")
        succeed("systemctl stop orchard")  # Cancel the automatic retry.
        assert_running("cdk-mintd")
        assert succeed("systemctl show -P InvocationID cdk-mintd") == mint_invocation
        assert succeed_json(f"curl -fsS {mint_url}/info")["name"] == "Bitcoinix test mint"
    finally:
        succeed(f"chown {database_owner} {database}")
    succeed("systemctl start orchard")
    machine.wait_until_succeeds(f"curl -fsS {url}/config.json")
    assert query_ok('{ mint_keysets { id } }', login())["mint_keysets"]
