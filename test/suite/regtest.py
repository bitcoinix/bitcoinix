@test("regtest")
def test_regtest():
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
        # electrs serves requests while it is still indexing
        machine.wait_until_succeeds(
            f"[[ $({get_block_height(ip('electrs'), 50001)}) == {num_blocks} ]]"
        )
        # The history of the address that mined the blocks is in the index
        block = succeed_json("bitcoin-cli getblock $(bitcoin-cli getblockhash 1) 2")
        script = block["tx"][0]["vout"][0]["scriptPubKey"]["hex"]
        scripthash = hashlib.sha256(bytes.fromhex(script)).digest()[::-1].hex()
        history = succeed_json(
            f"""echo '{{"method": "blockchain.scripthash.get_history", "params": ["{scripthash}"], "id": 0}}'"""
            f" | nc {ip('electrs')} 50001 | head -1"
        )
        assert history["result"], f"electrs returned no history for {scripthash}: {history}"

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
        # BTCPay 2.4.5 blocks outbound requests to private addresses by default
        # and the internal lnd REST API is one. The `btcpayserver` test curls lnd
        # itself, so only a Greenfield request exercises BTCPay's own HTTP client.
        api = f"http://{ip('btcpayserver')}:23000/api/v1"
        user = "admin@example.com"
        password = "Greenfield-Test-Password-1"
        # The first user is created without authentication and becomes the admin.
        # A rerun of this test finds the user in place and skips the request.
        succeed(
            f"curl -fsS -u {user}:{password} {api}/users/me >/dev/null || "
            f"curl -fsS -X POST {api}/users -H 'Content-Type: application/json' "
            f"""-d '{{"email": "{user}", "password": "{password}", "isAdministrator": true}}'"""
        )
        info = succeed_json(f"curl -fsS -u {user}:{password} {api}/server/lightning/BTC/info")
        assert info["blockHeight"] == num_blocks, info
        machine.wait_until_succeeds(f"[[ $(curl -fsS {api}/health | jq -M .synchronized) == true ]]")

    if enabled("mempool"):
        assert_running("nginx")
        machine.wait_until_succeeds(
            f"[[ $(curl -fsS http://{ip('nginx')}:60845/api/v1/blocks/tip/height) == {num_blocks} ]]"
        )


@test("trustedcoin")
def test_trustedcoin():
    def expect_clightning_log(str):
        machine.wait_until_succeeds(log_has_string("clightning", str))

    expect_clightning_log(r"plugin-trustedcoin\b.*?\bbitcoind RPC working")
    if "regtest" in enabled_tests:
        num_blocks = test_data["num_blocks"]
        expect_clightning_log(rf"plugin-trustedcoin\b.*?\breturning block {num_blocks}")
