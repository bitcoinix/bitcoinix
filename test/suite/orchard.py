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
    for path in [data["seedFile"], f"{data['secretsDir']}/orchard-rpc-server-key",
                 f"{data['secretsDir']}/orchard-rpc-ca-key", "/run/cdk-mintd/lnd.macaroon"]:
        machine.fail(f"{as_orchard} cat {path}")
    machine.fail(f"{as_orchard} test -w {data['mintDataDir']}")
    machine.fail(f"runuser -u nobody -- cat {data['setupKeyFile']}")
    # Check the same RPC with and without credentials, so proto parsing or an
    # unavailable listener cannot make the authentication test pass spuriously.
    rpc = (f"grpcurl -H 'x-cdk-protocol-version: 1.0.0' -connect-timeout 3 -max-time 5 -cacert {data['secretsDir']}/orchard-rpc-ca-cert "
           f"-import-path {os.path.dirname(data['proto'])} -proto {os.path.basename(data['proto'])}")
    method = f"{data['rpcAddress']}:{data['mintRpcPort']} cdk_mint_management_v1.CdkMint/GetInfo"
    rpc_info = succeed_json(
        f"{rpc} -cert {data['secretsDir']}/orchard-rpc-client-cert "
        f"-key {data['secretsDir']}/orchard-rpc-client-key {method}"
    )
    assert rpc_info["name"] == "Orchard test mint", rpc_info
    machine.fail(f"{rpc} {method}")
    crypto_key = succeed(f"sha256sum {data['dataDir']}/crypto.key")
    succeed("systemctl stop cdk-mintd")
    machine.wait_until_succeeds("test $(systemctl is-active orchard) = inactive")
    succeed("systemctl start cdk-mintd")
    machine.wait_for_unit("orchard")
    machine.wait_until_succeeds(f"curl -fsS {url}/config.json")
    assert succeed(f"sha256sum {data['dataDir']}/crypto.key") == crypto_key
    # Accounts persist but JWTs deliberately don't survive an Orchard restart.
    token = query_ok('mutation { auth_authentication(authentication: {name: "admin", password: "test-password-long"}) { access_token } }')["auth_authentication"]["access_token"]
    result = query_ok('{ mint_info_rpc { name } mint_balances { keyset balance } mint_keysets { id } }', token)
    assert result["mint_info_rpc"]["name"] == "Orchard test mint", result
    assert result["mint_balances"] == [], result
    assert result["mint_keysets"], result
    query_ok('mutation { mint_name_update(name: "Bitcoinix test mint") { name } }', token)
