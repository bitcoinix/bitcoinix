@test("cdk-mintd")
def test_cdk_mintd():
    data = test_data["cdk-mintd"]
    assert_running("cdk-mintd")
    url = f"http://{ip('cdk-mintd')}:{data['port']}/v1"
    machine.wait_until_succeeds(f"curl -fsS {url}/info")
    info = succeed_json(f"curl -fsS {url}/info")
    assert info["name"] == "Bitcoinix test mint", info
    methods = {m["method"] for m in info["nuts"]["4"]["methods"]}
    assert "bolt11" in methods, info
    assert ("onchain" in methods) == data["onchain"], info
    keys = succeed_json(f"curl -fsS {url}/keys")
    assert keys["keysets"], keys
    seed_hash = succeed(f"sha256sum {data['seedFile']}")
    machine.fail(f"runuser -u nobody -- cat {data['seedFile']}")
    assert_full_match(f"stat -c '%U %a' {data['dataDir']}", f"{data['user']} 700\n")

    def post(path, body):
        return f"curl -fsS -H 'Content-Type: application/json' -d {shlex.quote(json.dumps(body))} {url}/{path}"

    # A real invoice from the selected backend, not the fake-wallet backend.
    command = post("mint/quote/bolt11", {"amount": 1000, "unit": "sat"})
    machine.wait_until_succeeds(command + " | jq -e '.request | startswith(\"lnbcrt\")'")
    quote = succeed_json(command)
    assert quote["state"] == "UNPAID", quote
    if data["backend"] == "lnd":
        invoice = succeed_json(f"lncli decodepayreq {quote['request']}")
        assert invoice["destination"] == succeed_json("lncli getinfo")["identity_pubkey"]
    else:
        invoices = succeed_json("lightning-cli listinvoices")["invoices"]
        assert any(i["bolt11"] == quote["request"] for i in invoices), invoices

    # Force the configuration-apply path, as on a changed Nix configuration.
    # The database, signing identity and outstanding quote must survive it.
    succeed(f"rm {data['dataDir']}/nix-config", "systemctl restart cdk-mintd")
    machine.wait_until_succeeds(f"curl -fsS {url}/info")
    assert succeed_json(f"curl -fsS {url}/keys") == keys
    assert succeed_json(f"curl -fsS {url}/mint/quote/bolt11/{quote['quote']}")["state"] == "UNPAID"
    assert succeed(f"sha256sum {data['seedFile']}") == seed_hash

    if not data["onchain"]:
        machine.fail(f"test -e {data['dataDir']}/bdk_wallet")
        machine.fail("test -e /secrets/cdk-mintd-bdk-mnemonic")

    # Stopping a backend stops the mint; starting it brings the mint back.
    if data["backend"] == "lnd":
        wait_for_lnd_server()
    succeed(f"systemctl stop {data['backend']}")
    machine.wait_until_succeeds("test $(systemctl is-active cdk-mintd) = inactive")
    succeed(f"systemctl start {data['backend']}")
    machine.wait_until_succeeds(f"curl -fsS {url}/info")
    assert succeed_json(f"curl -fsS {url}/keys") == keys


# Mines blocks after the common regtest checks have checked the fixture height.
@test("cdk-mintd-onchain")
def test_cdk_mintd_onchain():
    data = test_data["cdk-mintd"]
    url = f"http://{ip('cdk-mintd')}:{data['port']}/v1"
    # On-chain quotes require a public key for mint authorization.
    body = {"amount": 10000, "unit": "sat",
            "pubkey": "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"}
    onchain = succeed_json(
        f"curl -fsS -H 'Content-Type: application/json' -d {shlex.quote(json.dumps(body))}"
        f" {url}/mint/quote/onchain"
    )
    address = onchain["request"]
    assert address.startswith("bcrt1"), onchain
    # Mature the fixture's coinbase, fund BDK and wait for its RPC scanner.
    succeed("bitcoin-cli -rpcwallet=test -generate 1")
    succeed(f"bitcoin-cli -rpcwallet=test -named sendtoaddress address={address} amount=0.0001 fee_rate=1")
    succeed("bitcoin-cli -rpcwallet=test -generate 1")
    check = f"curl -fsS {url}/mint/quote/onchain/{onchain['quote']}"
    machine.wait_until_succeeds(check + " | jq -e '.amount_paid == 10000'", timeout=180)
    succeed("systemctl restart cdk-mintd")
    machine.wait_until_succeeds(check + " | jq -e '.amount_paid == 10000'")
