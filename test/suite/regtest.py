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
        # BTCPay 2.4.5 blocks outbound requests to private addresses by default
        # and the internal lnd REST API is one. The `btcpayserver` test curls lnd
        # itself, so only a Greenfield request exercises BTCPay's own HTTP client.
        api = f"http://{ip('btcpayserver')}:23000/api/v1"
        info = succeed_json(f'curl -fsS -u "{btcpayserver_admin()}" {api}/server/lightning/BTC/info')
        assert info["blockHeight"] == num_blocks, info
        machine.wait_until_succeeds(f"[[ $(curl -fsS {api}/health | jq -M .synchronized) == true ]]")

    if enabled("mempool"):
        assert_running("nginx")
        machine.wait_until_succeeds(
            f"[[ $(curl -fsS http://{ip('nginx')}:60845/api/v1/blocks/tip/height) == {num_blocks} ]]"
        )
        # Exercise the API path used by the frontend's ROOT_NETWORK setting.
        genesis = succeed("bitcoin-cli getblockhash 0").strip()
        assert_full_match(
            f"curl -fsS http://{ip('nginx')}:60845/api/block-height/0", genesis
        )


# Impure: mines a block. Runs after `regtest`, which checks the block count.
@test("rbitcoin-mempool")
def test_rbitcoin_mempool():
    api = f"http://{ip('nginx')}:60845/api/v1"
    num_blocks = test_data["num_blocks"]

    # mempool authenticates with rbitcoin's cookie, so it gets no bitcoind RPC user
    succeed("! test -e /secrets/bitcoin-rpcpassword-mempool")

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
def test_trustedcoin():
    def expect_clightning_log(str):
        machine.wait_until_succeeds(log_has_string("clightning", str))

    expect_clightning_log(r"plugin-trustedcoin\b.*?\bbitcoind RPC working")
    if "regtest" in enabled_tests:
        num_blocks = test_data["num_blocks"]
        expect_clightning_log(rf"plugin-trustedcoin\b.*?\breturning block {num_blocks}")
