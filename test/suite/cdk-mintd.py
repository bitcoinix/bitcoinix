@test("cdk-mintd")
def test_cdk_mintd():
    data = test_data["cdk-mintd"]
    assert_running("cdk-mintd")
    url = f"http://{ip('cdk-mintd')}:{data['port']}/v1"
    info = json.loads(machine.wait_until_succeeds(f"curl -fsS {url}/info"))
    assert info["name"] == "Bitcoinix test mint", info
    methods = {m["method"] for m in info["nuts"]["4"]["methods"]}
    assert "bolt11" in methods, info
    assert ("onchain" in methods) == data["onchain"], info
    keys = succeed_json(f"curl -fsS {url}/keys")
    assert keys["keysets"], keys
    seed_hash = succeed(f"sha256sum {data['seedFile']}")
    machine.fail(f"runuser -u nobody -- cat {data['seedFile']}")
    # Orchard receives directory traversal through a named, read-only DB group.
    mode = "710" if test_data.get("orchard") else "700"
    assert_full_match(f"stat -c '%U %a' {data['dataDir']}", f"{data['user']} {mode}\n")
    machine.fail(f"test -d {data['dataDir']}/logs")
    guard = "/var/lib/nixos/cdk-mintd/initialized"
    assert_full_match(f"stat -c '%U' {guard}", "root\n")
    machine.fail(f"runuser -u {data['user']} -- rm -f {guard}")

    def post(path, body):
        return f"curl -fsS -H 'Content-Type: application/json' -d {shlex.quote(json.dumps(body))} {url}/{path}"

    # A real invoice from the selected backend, not the fake-wallet backend.
    command = post("mint/quote/bolt11", {"amount": 1000, "unit": "sat"})
    quote = json.loads(machine.wait_until_succeeds(
        command + " | jq -e 'select(.request | startswith(\"lnbcrt\"))'"
    ))
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

    if data["generatedSeed"]:
        # After a fresh deployment with generated secrets, both units are
        # already active. Starting the target cannot repair restored file modes.
        succeed("systemctl stop cdk-mintd",
                f"chown root:root {data['seedFile']}", f"chmod 600 {data['seedFile']}",
                "systemctl start nix-bitcoin-secrets.target")
        machine.fail(f"runuser -u {data['user']} -- test -r {data['seedFile']}")
        succeed("systemctl reset-failed setup-secrets.service",
                "systemctl restart setup-secrets.service",
                "systemctl start nix-bitcoin-secrets.target",
                "systemctl start cdk-mintd")
        assert_full_match(f"stat -c '%U %G %a' {data['seedFile']}",
                          f"{data['user']} {data['group']} 440\n")
        assert succeed(f"sha256sum {data['seedFile']}") == seed_hash
        machine.wait_until_succeeds(f"curl -fsS {url}/info")

    # Losing the database must fail closed even if nix-config survives. Keep the
    # original state and restore it afterwards, as a real recovery would do.
    directory = data["dataDir"]
    succeed("systemctl stop cdk-mintd", f"mv {directory} {directory}.saved",
            f"install -d -o {data['user']} -g {data['group']} -m 700 {directory}",
            f"cp -a {directory}.saved/nix-config {directory}/")
    # A private directory (e.g. restored under umask 077) must not hide the
    # marker and authorize a new mint. Check read and search permission failures.
    guard_dir = os.path.dirname(guard)

    def refuse_initialization():
        succeed("systemctl reset-failed cdk-mintd")
        machine.fail("systemctl start cdk-mintd")
        machine.fail(f"test -e {directory}/cdk-mintd.sqlite")
        invocation = succeed("systemctl show -P InvocationID cdk-mintd").strip()
        assert invocation
        log = succeed(f"journalctl _SYSTEMD_INVOCATION_ID={invocation} --no-pager")
        assert "Unsafe initialization guard directory" in log, log
        assert "original initialization marker" in log, log
        succeed("systemctl stop cdk-mintd")

    for mode in ["700", "744"]:
        succeed(f"chmod {mode} {guard_dir}")
        refuse_initialization()
    succeed(f"chmod 755 {guard_dir}", f"mv {guard_dir} {guard_dir}.saved")
    refuse_initialization()
    # All of these pass a read/search permission check but are unsafe guards.
    succeed(f"install -m 755 /dev/null {guard_dir}")
    refuse_initialization()
    succeed(f"rm {guard_dir}", f"install -d -m 755 {guard_dir}.target",
            f"ln -s {guard_dir}.target {guard_dir}")
    refuse_initialization()
    succeed(f"rm {guard_dir}", f"rmdir {guard_dir}.target",
            f"install -d -m 755 -o {data['user']} -g {data['group']} {guard_dir}")
    refuse_initialization()
    succeed(f"chown root:root {guard_dir}", f"chmod 777 {guard_dir}")
    refuse_initialization()
    succeed(f"chmod 755 {guard_dir}")
    for path in [guard_dir, "/var/lib/nixos"]:
        succeed(f"setfacl -m u:{data['user']}:rwx {path}",
                f"runuser -u {data['user']} -- test -w {path}")
        refuse_initialization()
        succeed(f"setfacl -b {path}", f"chmod 755 {path}")
    succeed(f"rmdir {guard_dir}", f"mv {guard_dir}.saved {guard_dir}", "systemctl reset-failed cdk-mintd")
    machine.fail("systemctl start cdk-mintd")
    succeed("journalctl -u cdk-mintd | grep -F 'Refusing to recreate an initialized mint'",
            "systemctl stop cdk-mintd", f"rm -rf {directory}",
            f"mv {directory}.saved {directory}", "systemctl reset-failed cdk-mintd",
            "systemctl start cdk-mintd")
    machine.wait_until_succeeds(f"curl -fsS {url}/info")
    assert succeed_json(f"curl -fsS {url}/keys") == keys

    if data["onchain"]:
        # Keep the backend running to isolate the mint's direct Bitcoin Core
        # dependency from the backend's own restart hook.
        backend_invocation = succeed(f"systemctl show -P InvocationID {data['backend']}")
        bitcoin_pid = succeed("systemctl show -P MainPID bitcoind").strip()
        # Flush regtest's freshly mined chain on exit; SIGKILL can lose those
        # blocks and make Lightning abort independently of systemd dependencies.
        succeed("mkdir -p /run/systemd/system/bitcoind.service.d",
                "printf '[Service]\\nRestart=always\\nRestartSec=3s\\n' > /run/systemd/system/bitcoind.service.d/cdk-restart.conf",
                # Dependency lists cannot be cleared with a drop-in. Override
                # the unit in the higher-priority runtime directory instead.
                "mkdir -p /run/systemd/system.control",
                f"sed '/^Requires=/d' /etc/systemd/system/{data['backend']}.service"
                f" > /run/systemd/system.control/{data['backend']}.service",
                "systemctl daemon-reload",
                f"! systemctl show -P Requires {data['backend']} | grep -w bitcoind.service",
                "bitcoin-cli stop")
        machine.wait_until_succeeds("test $(systemctl is-active cdk-mintd) = inactive")
        machine.wait_until_succeeds(
            f"test $(systemctl show -P MainPID bitcoind) != {bitcoin_pid} && bitcoin-cli getnetworkinfo")
        machine.wait_until_succeeds(f"curl -fsS {url}/info")
        assert succeed(f"systemctl show -P InvocationID {data['backend']}") == backend_invocation
        assert succeed_json(f"curl -fsS {url}/keys") == keys
        succeed("rm /run/systemd/system/bitcoind.service.d/cdk-restart.conf",
                f"rm /run/systemd/system.control/{data['backend']}.service",
                "systemctl daemon-reload")
    assert succeed_json(f"curl -fsS {url}/mint/quote/bolt11/{quote['quote']}")["state"] == "UNPAID"

    if data["backend"] == "lnd":
        # lnd can replace its macaroon file, but cannot trick the mint into
        # reading and sending a signing secret through a substituted symlink.
        macaroon = "/run/lnd/cdk-mintd.macaroon"
        succeed("systemctl stop cdk-mintd", f"mv {macaroon} {macaroon}.saved",
                f"runuser -u lnd -- ln -s {data['seedFile']} {macaroon}")
        machine.fail("systemctl start cdk-mintd")
        succeed("systemctl stop cdk-mintd", f"rm {macaroon}",
                f"mv {macaroon}.saved {macaroon}", "systemctl reset-failed cdk-mintd",
                "systemctl start cdk-mintd")
        machine.wait_until_succeeds(f"curl -fsS {url}/info")

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


def start_cdk_wallet_command(unit, command):
    # Run the wallet while the driver funds its quote or confirms its payout.
    # Retain the exit status and output so a failed CLI cannot pass the test.
    log = f"/tmp/{unit}.log"
    succeed(f"systemd-run --unit={unit} --property=Type=exec --property=RemainAfterExit=yes "
            f"--property=RuntimeMaxSec=180s --property=StandardOutput=file:{log} "
            f"--property=StandardError=inherit {command}")
    return log


def finish_cdk_wallet_command(unit):
    machine.wait_until_succeeds(
        f"[[ $(systemctl show -P SubState {unit}) =~ ^(exited|failed)$ ]]", timeout=180)
    output = succeed(f"cat /tmp/{unit}.log")
    assert succeed(f"systemctl show -P Result {unit}").strip() == "success", output
    assert succeed(f"systemctl show -P ExecMainStatus {unit}").strip() == "0", output
    succeed(f"systemctl stop {unit}")
    return output


# Mine only after regtest has checked the common fixture's height.
@test("cdk-mintd-lightning")
def test_cdk_mintd_lightning():
    data = test_data["cdk-mintd"]
    mint_url = f"http://{ip('cdk-mintd')}:{data['port']}"
    cli = f"{data['walletCli']} --work-dir /tmp/cdk-wallet-lightning --unit sat --non-interactive"
    wait_for_lnd_server()
    peer = succeed_json("lightning-cli -J getinfo")["id"]
    succeed("bitcoin-cli -rpcwallet=test -generate 1")
    address = succeed_json("lncli newaddress p2wkh")["address"]
    succeed(f"bitcoin-cli -rpcwallet=test -named sendtoaddress address={address} amount=0.02 fee_rate=1",
            "bitcoin-cli -rpcwallet=test -generate 6")
    machine.wait_until_succeeds("lncli walletbalance | jq -e '.confirmed_balance | tonumber >= 2000000'")
    succeed(f"lncli connect {peer}@{ip('clightning')}:{data['peerPort']}",
            f"lncli openchannel --node_key={peer} --local_amt=1000000 --push_amt=200000 --sat_per_vbyte=1",
            "bitcoin-cli -rpcwallet=test -generate 6")
    machine.wait_until_succeeds("lncli listchannels | jq -e '.channels | any(.active)'", timeout=120)
    machine.wait_until_succeeds(
        "lightning-cli -J listpeerchannels | jq -e '.channels | any(.state == \"CHANNELD_NORMAL\")'", timeout=120)

    # Fund ecash through a real channel payment from the independent peer.
    log = start_cdk_wallet_command("cdk-lightning-mint", f"{cli} mint --wait-duration 60 {mint_url} 100000")
    machine.wait_until_succeeds(f"grep -q '^Please pay: lnbcrt' {log}")
    request = re.search(r"^Please pay: (\S+)", succeed(f"cat {log}"), re.MULTILINE)
    assert request is not None
    paid = succeed_json(f"lightning-cli -J -N none pay {request.group(1)}")
    assert paid["status"] == "complete", paid
    assert "Minted 100000 sat" in finish_cdk_wallet_command("cdk-lightning-mint")
    assert "Total balance across all wallets: 100000 sat" in succeed(f"{cli} balance")

    # The normal path uses SendPaymentV2; a full-amount MPP part exercises
    # QueryRoutes and SendToRouteV2 without needing another mint.
    for mpp, amount in [(False, 5000), (True, 10000)]:
        label = f"cdk-melt-{mpp}"
        invoice = succeed_json(f"lightning-cli -J invoice {amount * 1000} {label} cdk-melt")
        machine.wait_until_succeeds(f"lncli queryroutes {peer} {amount} | jq -e '.routes | length > 0'")
        options = f"--mpp --mpp-split={mint_url}={amount}" if mpp else f"--mint-url {mint_url}"
        output = succeed(f"timeout 120 {cli} melt --method bolt11 --invoice {invoice['bolt11']} {options}")
        preimage = re.search(r"[Pp]reimage: ([0-9a-f]{64})", output)
        assert preimage is not None, output
        assert hashlib.sha256(bytes.fromhex(preimage.group(1))).hexdigest() == invoice["payment_hash"]
        received = succeed_json(f"lightning-cli -J listinvoices {label}")["invoices"][0]
        assert received["status"] == "paid", received
        assert received["amount_received_msat"] == amount * 1000, received
        # Use exactly the mint's restricted macaroon, not the admin wrapper,
        # to check TrackPaymentV2 on the completed outgoing payment.
        tracked = succeed_json(f"{data['lndCli']} trackpayment --json {invoice['payment_hash']}")
        assert tracked["status"] == "SUCCEEDED", tracked
        assert tracked["payment_preimage"] == preimage.group(1), tracked


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

    # Only the allowNewWallet option changes, with the same rescan height and
    # TOML. Applying the alternate Nix-generated preStart must permit recovery.
    directory = data["dataDir"]
    marker = succeed(f"readlink {directory}/nix-config")
    succeed("systemctl stop cdk-mintd", f"mv {directory}/bdk_wallet {directory}/bdk_wallet.saved")
    succeed("systemctl start cdk-mintd")
    machine.wait_until_succeeds("test $(systemctl show -P SubState cdk-mintd) = auto-restart")
    machine.fail(f"curl -fsS {url}/info")
    succeed("systemctl stop cdk-mintd", "mkdir -p /run/systemd/system/cdk-mintd.service.d")
    machine.succeed(
        "cat > /run/systemd/system/cdk-mintd.service.d/recovery.conf <<'EOF'\n"
        f"[Service]\nExecStartPre=\nExecStartPre={test_data['cdk-mintd-recovery-pre-start']}\nEOF\n"
        "systemctl daemon-reload\nsystemctl reset-failed cdk-mintd\nsystemctl start cdk-mintd"
    )
    machine.wait_until_succeeds(check + " | jq -e '.amount_paid == 10000'", timeout=180)
    assert succeed(f"readlink {directory}/nix-config") != marker
    succeed("rm /run/systemd/system/cdk-mintd.service.d/recovery.conf",
            "systemctl daemon-reload", "systemctl restart cdk-mintd")
    machine.wait_until_succeeds(check + " | jq -e '.amount_paid == 10000'")
    assert succeed(f"readlink {directory}/nix-config") == marker
    succeed(f"rm -rf {directory}/bdk_wallet.saved")

    # Mint spendable ecash, then redeem it through BDK's sendrawtransaction
    # path. A paid deposit quote alone never exercises signing or sending.
    mint_url = url.removesuffix("/v1")
    cli = f"{data['walletCli']} --work-dir /tmp/cdk-wallet-onchain --unit sat --non-interactive"
    log = start_cdk_wallet_command(
        "cdk-onchain-mint", f"{cli} mint --method onchain --wait-duration 60 {mint_url} 100000")
    machine.wait_until_succeeds(f"grep -q '^Send sats to: bcrt1' {log}")
    request = re.search(r"^Send sats to: (\S+)", succeed(f"cat {log}"), re.MULTILINE)
    assert request is not None
    address = request.group(1)
    succeed(f"bitcoin-cli -rpcwallet=test -named sendtoaddress address={address} amount=0.001 fee_rate=1",
            "bitcoin-cli -rpcwallet=test -generate 1")
    assert "Minted 100000 sat" in finish_cdk_wallet_command("cdk-onchain-mint")
    assert "Total balance across all wallets: 100000 sat" in succeed(f"{cli} balance")

    payout_address = succeed("bitcoin-cli -rpcwallet=test getnewaddress").strip()
    log = start_cdk_wallet_command(
        "cdk-onchain-melt", f"{cli} melt --method onchain --mint-url {mint_url} "
        f"--address {payout_address} --amount 50000")
    machine.wait_until_succeeds(
        f"bitcoin-cli -rpcwallet=test getreceivedbyaddress {payout_address} 0 | grep -Fx 0.00050000", timeout=180)
    outputs = succeed_json(
        f"bitcoin-cli -rpcwallet=test listunspent 0 9999999 '{json.dumps([payout_address])}'")
    assert len(outputs) == 1, outputs
    payout = outputs[0]
    assert payout["confirmations"] == 0, payout
    succeed("bitcoin-cli -rpcwallet=test -generate 1")
    output = finish_cdk_wallet_command("cdk-onchain-melt")
    assert "Payment successful: state=PAID, amount=50000" in output, output
    quote_id = re.search(r"Quote ID: (\S+)", output)
    assert quote_id is not None, output
    quote = succeed_json(f"curl -fsS {url}/melt/quote/onchain/{quote_id.group(1)}")
    assert quote["state"] == "PAID", quote
    assert quote["outpoint"] == f"{payout['txid']}:{payout['vout']}", quote
    transaction = succeed_json(f"bitcoin-cli -rpcwallet=test gettransaction {payout['txid']}")
    assert transaction["confirmations"] >= 1, transaction
    assert_full_match(f"bitcoin-cli -rpcwallet=test getreceivedbyaddress {payout_address} 1", "0.00050000\n")


@test("cdk-mintd-backup")
def test_cdk_mintd_backup():
    data = test_data["cdk-mintd"]
    directory, user, group = data["dataDir"], data["user"], data["group"]
    url = f"http://{ip('cdk-mintd')}:{data['port']}/v1"
    stage = "/var/lib/cdk-mintd-backup"
    current = f"{stage}/current"
    duplicity = "export $(cat /secrets/backup-encryption-env); duplicity"
    destination = "file:///var/lib/localBackups"

    def ready():
        machine.wait_until_succeeds(f"curl -fsS {url}/info")

    def files():
        return succeed(f"{duplicity} list-current-files {destination}")

    # /etc/systemd/system (NixOS units) overrides ordinary --runtime masks.
    # system.control is the higher-priority runtime unit path.
    def mask(*units):
        succeed("mkdir -p /run/systemd/system.control")
        for unit in units:
            succeed(f"ln -s /dev/null /run/systemd/system.control/{unit}.service")
        succeed("systemctl daemon-reload")
        for unit in units:
            assert_full_match(f"systemctl show -P LoadState {unit}", "masked\n")

    def unmask(*units):
        for unit in units:
            succeed(f"rm /run/systemd/system.control/{unit}.service")
        succeed("systemctl daemon-reload")

    ready()
    keys = succeed_json(f"curl -fsS {url}/keys")
    quote = succeed_json(
        f"curl -fsS -H 'Content-Type: application/json' -d '{{\"amount\":1000,\"unit\":\"sat\"}}'"
        f" {url}/mint/quote/bolt11"
    )
    seed_hash = succeed(f"sha256sum {data['seedFile']}").split()[0]
    # Archive symlinks without following them as root.
    succeed("install -m 600 <(echo root-secret) /root/cdk-backup-canary",
            f"runuser -u {user} -- ln -s /root/cdk-backup-canary {directory}/root-link",
            f"install -o root -g {group} -m 640 <(echo service-group) {directory}/group-readable",
            f"runuser -u {user} -- truncate -s 2G {directory}/sparse",
            f"install -o {user} -g {group} -m 777 <(echo private) {directory}/wide-mode")
    before = succeed("systemctl show -P InvocationID cdk-mintd")
    succeed("systemctl start duplicity")
    ready()
    assert succeed("systemctl show -P InvocationID cdk-mintd") != before
    assert_full_match(f"stat -c '%U %a' {stage}", "root 700\n")
    machine.fail(f"runuser -u {user} -- cat {current}/seed")
    assert int(succeed(f"stat -c %s {current}/data.tar")) < 64 * 1024 * 1024
    archived = files()
    guard = "/var/lib/nixos/cdk-mintd/initialized"
    assert guard.lstrip('/') in archived, archived
    assert "secrets/cdk-mintd-seed" not in archived, archived
    assert f"{directory.lstrip('/')}/cdk-mintd.sqlite" not in archived, archived
    assert f"{stage.lstrip('/')}/.next" not in archived, archived
    for file in ["data.tar", "seed", "bdk-mnemonic", "manifest.json", "created-at"]:
        assert f"{current.lstrip('/')}/{file}" in archived, archived
    assert succeed_json(f"cat {current}/manifest.json") == {
        "format": 1, "dataDir": directory, "seedFile": data["seedFile"],
        "mnemonicFile": data["mnemonicFile"],
    }

    # Restore from duplicity, not directly from the staging directory. Extract as
    # the mint user: a symlink planted by the mint must never redirect root writes.
    restored = "/tmp/cdk-restored"
    succeed(f"{duplicity} restore --path-to-restore {current.lstrip('/')} {destination} {restored}")
    mask("duplicity", "cdk-mintd-backup", "cdk-mintd")
    succeed("systemctl stop cdk-mintd",
            # Emulate a new host with the old seed but no database or marker.
            "mv /var/lib/nixos/cdk-mintd/initialized /tmp/cdk-initialized.saved",
            f"mv {directory} {directory}.before-restore",
            f"install -d -o {user} -g {group} -m 700 {directory}")
    succeed(f"systemctl restart {data['backend']}")
    machine.fail("systemctl start cdk-mintd")
    machine.fail(f"test -e {directory}/cdk-mintd.sqlite")
    # A protected deployment without supplied secrets fails setup-secrets and
    # leaves /secrets inaccessible until the secrets target is started again.
    succeed(f"mv {data['seedFile']} /tmp/cdk-seed.saved")
    machine.fail("systemctl restart setup-secrets")
    assert_full_match("stat -c %a /secrets", "700\n")
    succeed(f"(umask 077; setpriv --reuid={user} --regid={group} --init-groups -- "
            f"tar --no-same-owner --no-same-permissions -xf - -C {directory} < {restored}/data.tar)",
            f"install -o root -g root -m 600 {restored}/seed {data['seedFile']}",
            f"install -o root -g root -m 600 {restored}/bdk-mnemonic {data['mnemonicFile']}")
    assert_full_match(f"stat -c '%a' {directory}/wide-mode", "700\n")
    assert_full_match(f"runuser -u {user} -- sqlite3 {directory}/cdk-mintd.sqlite 'PRAGMA integrity_check'", "ok\n")
    assert_full_match(f"runuser -u {user} -- sqlite3 {directory}/bdk_wallet/bdk_wallet.sqlite 'PRAGMA integrity_check'", "ok\n")
    assert_full_match(f"readlink {directory}/root-link", "/root/cdk-backup-canary\n")
    assert_full_match("cat /root/cdk-backup-canary", "root-secret\n")
    assert succeed(f"sha256sum {data['seedFile']}").split()[0] == seed_hash
    succeed(f"{duplicity} restore --path-to-restore {guard.lstrip('/')} {destination} /tmp/cdk-initialized.restored",
            f"install -o root -g root -m 600 /tmp/cdk-initialized.restored {guard}",
            "systemctl reset-failed setup-secrets.service",
            "systemctl restart setup-secrets.service",
            "systemctl start nix-bitcoin-secrets.target",
            "rm /tmp/cdk-initialized.saved /tmp/cdk-initialized.restored /tmp/cdk-seed.saved")
    succeed(f"runuser -u {user} -- test -r {data['seedFile']}")
    unmask("duplicity", "cdk-mintd-backup", "cdk-mintd")
    succeed("systemctl start cdk-mintd")
    ready()
    assert succeed_json(f"curl -fsS {url}/keys") == keys
    assert succeed_json(f"curl -fsS {url}/mint/quote/bolt11/{quote['quote']}")["state"] == "UNPAID"
    succeed(f"rm {directory}/sparse {directory}/wide-mode")

    # Unit setup can fail before the snapshot script gets to remove current.
    # A masked dump must not cause yesterday's database to enter today's backup.
    mask("cdk-mintd-backup")
    machine.fail("systemctl start duplicity")
    machine.fail(f"test -e {current}")
    assert f"{current.lstrip('/')}/data.tar" not in files()
    unmask("cdk-mintd-backup")
    succeed("systemctl reset-failed duplicity", "systemctl start duplicity")
    ready()

    # An intentionally stopped mint stays stopped after a successful snapshot.
    succeed("systemctl stop cdk-mintd", "systemctl start cdk-mintd-backup")
    assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
    succeed("systemctl start cdk-mintd")
    ready()

    # Preserve a queued start whose dependency has not finished yet. Restarting
    # after the snapshot must not wait for that dependency to become ready.
    succeed("systemctl stop cdk-mintd", "touch /run/cdk-start-barrier",
            f"touch {directory}/pause-backup")
    machine.succeed(
        "cat > /run/systemd/system/cdk-start-barrier.service <<'EOF'\n"
        "[Service]\nType=oneshot\nRemainAfterExit=yes\nEnvironment=PATH=/run/current-system/sw/bin\n"
        "ExecStart=/bin/sh -c 'while test -e /run/cdk-start-barrier; do sleep 0.1; done'\nEOF\n"
        "mkdir -p /run/systemd/system/cdk-mintd.service.d\n"
        "cat > /run/systemd/system/cdk-mintd.service.d/barrier.conf <<'EOF'\n"
        "[Unit]\nRequires=cdk-start-barrier.service\nAfter=cdk-start-barrier.service\nEOF\n"
        "systemctl daemon-reload\nsystemctl start --no-block cdk-mintd"
    )
    machine.wait_until_succeeds("test $(systemctl show -P Job cdk-mintd) != 0")
    assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
    succeed("systemctl start --no-block cdk-mintd-backup")
    machine.wait_until_succeeds(f"test -d {stage}/.next")
    machine.wait_until_succeeds("systemctl list-jobs --no-legend cdk-mintd.service | grep -w start")
    succeed(f"rm {directory}/pause-backup", "timeout 30 systemctl start cdk-mintd-backup")
    assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
    succeed("rm /run/cdk-start-barrier")
    ready()
    succeed("rm /run/systemd/system/cdk-mintd.service.d/barrier.conf",
            "systemctl daemon-reload")

    # A start arriving after the backup observes an inactive mint must remain
    # queued throughout the copy, not get cancelled by a redundant stop command.
    succeed("systemctl stop cdk-mintd", f"touch {stage}/pause-state-check",
            f"touch {directory}/pause-backup", "systemctl start --no-block cdk-mintd-backup")
    machine.wait_until_succeeds(f"test -e {stage}/state-checked")
    succeed(f"systemctl restart {data['backend']}")
    machine.wait_until_succeeds("systemctl list-jobs --no-legend cdk-mintd.service | grep -w start")
    job = succeed("systemctl show -P Job cdk-mintd")
    succeed(f"rm {stage}/pause-state-check")
    machine.wait_until_succeeds(f"test -d {stage}/.next")
    assert succeed("systemctl show -P Job cdk-mintd") == job
    assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
    succeed(f"rm {directory}/pause-backup", "systemctl start cdk-mintd-backup",
            f"rm {stage}/state-checked")
    ready()

    # An explicit stop during copying cancels the queued restart. Neither normal
    # completion nor cancellation of the backup may resurrect that request.
    for cancel in [False, True]:
        succeed(f"touch {directory}/pause-backup", "systemctl start --no-block cdk-mintd-backup")
        machine.wait_until_succeeds(f"test -d {stage}/.next")
        machine.wait_until_succeeds("systemctl list-jobs --no-legend cdk-mintd.service | grep -w start")
        succeed("systemctl stop cdk-mintd")
        assert succeed("systemctl show -P Job cdk-mintd").strip() in ("", "0")
        if cancel:
            succeed("systemctl stop cdk-mintd-backup", f"rm {directory}/pause-backup")
            machine.fail(f"test -e {current}")
        else:
            succeed(f"rm {directory}/pause-backup", "systemctl start cdk-mintd-backup")
        assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
        assert succeed("systemctl show -P Job cdk-mintd").strip() in ("", "0")
        machine.fail(f"test -e {stage}/.next")
        succeed("systemctl reset-failed cdk-mintd cdk-mintd-backup", "systemctl start cdk-mintd")
        ready()

    # A copy error restarts the mint, removes stale/partial staging, backs up
    # unrelated files, and fails duplicity after it has archived those files.
    succeed(f"install -m 600 <(echo unreadable) {directory}/unreadable",
            "touch /var/lib/nixos/cdk-backup-other")
    machine.fail("systemctl start duplicity")
    ready()
    machine.fail(f"test -e {current}")
    machine.fail(f"test -e {stage}/.next")
    archived = files()
    assert f"{current.lstrip('/')}/data.tar" not in archived, archived
    assert "var/lib/nixos/cdk-backup-other" in archived, archived
    succeed(f"rm {directory}/unreadable", "systemctl reset-failed duplicity cdk-mintd-backup")

    # Backend/manual starts cannot race the copy. Cancellation still unblocks
    # and fulfills a new start request made while a stopped mint is being copied.
    succeed("systemctl stop cdk-mintd", f"touch {directory}/pause-backup",
            "systemctl start --no-block cdk-mintd-backup")
    machine.wait_until_succeeds(f"test -d {stage}/.next")
    succeed(f"systemctl restart {data['backend']}", "systemctl start --no-block cdk-mintd")
    machine.wait_until_succeeds("systemctl list-jobs --no-legend cdk-mintd.service | grep -w start")
    assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
    succeed("systemctl stop cdk-mintd-backup")
    ready()
    machine.fail(f"test -e {stage}/.next")
    machine.fail(f"test -e {current}")
    succeed(f"rm {directory}/pause-backup", "systemctl reset-failed cdk-mintd-backup",
            "systemctl start duplicity")
    ready()
    assert f"{current.lstrip('/')}/data.tar" in files()


@test("cdk-mintd-backup-shutdown")
def test_cdk_mintd_backup_shutdown():
    data = test_data["cdk-mintd"]
    backend = data["backend"]
    stage = "/var/lib/cdk-mintd-backup"
    barrier = "/run/cdk-shutdown-barrier"
    post_stop_barrier = "/run/cdk-post-stop-barrier"
    start_barrier = "/run/cdk-pre-start-barrier"
    pause_copy = f"{data['dataDir']}/pause-backup"
    url = f"http://{ip('cdk-mintd')}:{data['port']}/v1/info"

    def ready():
        machine.wait_until_succeeds("test $(systemctl show -P ActiveState cdk-mintd) = active")
        machine.wait_until_succeeds(f"curl -fsS {url}")
        if backend == "lnd":
            wait_for_lnd_server()

    ready()
    # A running mint can become masked or reach its start limit. Neither should
    # make a consistent snapshot wait for the backup's full start timeout.
    for blocked in ["masked", "start-limit"]:
        if blocked == "masked":
            succeed("mkdir -p /run/systemd/system.control",
                    "ln -s /dev/null /run/systemd/system.control/cdk-mintd.service",
                    "systemctl daemon-reload")
            assert_full_match("systemctl show -P LoadState cdk-mintd", "masked\n")
        else:
            succeed("mkdir -p /run/systemd/system/cdk-mintd.service.d",
                    "printf '[Unit]\\nStartLimitIntervalSec=1h\\nStartLimitBurst=1\\n'"
                    " > /run/systemd/system/cdk-mintd.service.d/start-limit.conf",
                    "systemctl daemon-reload", "systemctl reset-failed cdk-mintd",
                    "systemctl restart cdk-mintd")
            ready()
        assert_full_match("systemctl show -P ActiveState cdk-mintd", "active\n")
        succeed(f"touch {pause_copy}", "systemctl start --no-block cdk-mintd-backup")
        try:
            machine.wait_until_succeeds(f"test -d {stage}/.next", timeout=15)
        except Exception:
            print(succeed("journalctl -u cdk-mintd-backup --no-pager",
                          "systemctl list-jobs --no-legend",
                          "systemctl show -p ActiveState -p SubState -p Job cdk-mintd"))
            raise
        assert_full_match("systemctl show -P MainPID cdk-mintd", "0\n")
        succeed(f"rm {pause_copy}", "timeout 15 systemctl start cdk-mintd-backup")
        assert_full_match("systemctl show -P Result cdk-mintd-backup", "success\n")
        succeed(f"test -s {stage}/current/data.tar")
        if blocked == "masked":
            assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
            assert_full_match("systemctl show -P LoadState cdk-mintd", "masked\n")
            succeed("rm /run/systemd/system.control/cdk-mintd.service")
        else:
            machine.wait_until_succeeds("test $(systemctl show -P Result cdk-mintd) = start-limit-hit", timeout=15)
            succeed("rm /run/systemd/system/cdk-mintd.service.d/start-limit.conf")
        succeed("systemctl daemon-reload", "systemctl reset-failed cdk-mintd",
                "systemctl start cdk-mintd")
        ready()

    # Hold the mint in deactivating while it still has a live daemon. No archive
    # may begin here, and the restart must survive termination of the backup.
    machine.succeed(
        "mkdir -p /run/systemd/system/cdk-mintd.service.d\n"
        "cat > /run/systemd/system/cdk-mintd.service.d/slow-stop.conf <<'EOF'\n"
        "[Service]\nTimeoutStopSec=60s\n"
        "RestartSec=30s\nExecReload=/run/current-system/sw/bin/true\n"
        f"ExecStartPre=/bin/sh -c 'while test -e {start_barrier}; do /run/current-system/sw/bin/sleep 0.1; done'\n"
        f"ExecStop=/bin/sh -c 'while test -e {barrier}; do /run/current-system/sw/bin/sleep 0.1; done'\n"
        f"ExecStopPost=/bin/sh -c 'while test -e {post_stop_barrier}; do /run/current-system/sw/bin/sleep 0.1; done'\n"
        "EOF\n"
        # This dependent lets a stop be queued while the mint is still active,
        # so --job-mode=fail must reject the conflicting restart transaction.
        "cat > /run/systemd/system/cdk-shutdown-blocker.service <<'EOF'\n"
        "[Unit]\nRequires=cdk-mintd.service\nAfter=cdk-mintd.service\n"
        "[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/run/current-system/sw/bin/true\n"
        f"ExecStop=/bin/sh -c 'while test -e {barrier}; do /run/current-system/sw/bin/sleep 0.1; done'\n"
        "EOF\nsystemctl daemon-reload"
    )

    # The pinned systemd keeps try-restart jobs for activating units. Exercise
    # both a running preStart and RestartSec, rather than assuming active only.
    for starting in ["pre-start", "auto-restart"]:
        succeed(f"touch {pause_copy}")
        if starting == "pre-start":
            succeed("systemctl stop cdk-mintd", f"touch {start_barrier}",
                    "systemctl start --no-block cdk-mintd")
            machine.wait_until_succeeds("test $(systemctl show -P SubState cdk-mintd) = start-pre")
        else:
            succeed("systemctl kill --kill-whom=main --signal=KILL cdk-mintd")
            machine.wait_until_succeeds("test $(systemctl show -P SubState cdk-mintd) = auto-restart")
        succeed("systemctl start --no-block cdk-mintd-backup")
        machine.wait_until_succeeds(f"test -d {stage}/.next")
        assert_full_match("systemctl show -P MainPID cdk-mintd", "0\n")
        succeed(f"rm -f {start_barrier} {pause_copy}", "systemctl start cdk-mintd-backup")
        ready()

    # A stop already underway must finish before copying, and remain stopped.
    # Start the backup first so systemd's stop-before-start ordering doesn't
    # hold its entire start job behind the stop we're trying to observe.
    succeed(f"touch {barrier} {pause_copy} {stage}/pause-before-state-check",
            "systemctl start --no-block cdk-mintd-backup")
    machine.wait_until_succeeds(f"test -e {stage}/before-state-checked")
    succeed("systemctl stop --no-block cdk-mintd")
    machine.wait_until_succeeds("test $(systemctl show -P SubState cdk-mintd) = stop")
    succeed(f"rm {stage}/pause-before-state-check")
    machine.fail(f"test -d {stage}/.next")
    succeed(f"rm {barrier}")
    machine.wait_until_succeeds(f"test -d {stage}/.next")
    succeed(f"rm {pause_copy} {stage}/before-state-checked", "systemctl start cdk-mintd-backup")
    assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
    succeed("systemctl start cdk-mintd")
    ready()

    # A crash after is-active but before try-restart makes the latter a no-op
    # during deactivation. It must be retried once the automatic restart begins.
    succeed(f"touch {post_stop_barrier} {pause_copy} {stage}/pause-state-check",
            "systemctl start --no-block cdk-mintd-backup")
    machine.wait_until_succeeds(f"test -e {stage}/state-checked")
    succeed("systemctl kill --kill-whom=main --signal=KILL cdk-mintd")
    machine.wait_until_succeeds("test $(systemctl show -P SubState cdk-mintd) = stop-post")
    succeed(f"rm -f {stage}/restart-status", f"rm {stage}/pause-state-check")
    machine.wait_until_succeeds(f"test -s {stage}/restart-status")
    assert_full_match(f"cat {stage}/restart-status", "0\n")
    machine.fail(f"test -d {stage}/.next")
    succeed(f"rm {post_stop_barrier}")
    machine.wait_until_succeeds(f"test -d {stage}/.next")
    succeed(f"rm {pause_copy} {stage}/state-checked", "systemctl start cdk-mintd-backup")
    ready()

    for action in ["start", "reload"]:
        # Inject a rejected restart while a real start/reload is queued. The
        # snapshot must not replace it with a stop before retrying.
        succeed(f"touch {pause_copy} {stage}/pause-state-check {stage}/reject-restart",
                "systemctl start --no-block cdk-mintd-backup")
        machine.wait_until_succeeds(f"test -e {stage}/state-checked")
        succeed(f"systemctl {action} --no-block cdk-mintd")
        job = succeed(f"systemctl list-jobs --no-legend cdk-mintd.service | grep -w {action}").split()[0]
        succeed(f"rm -f {stage}/restart-status {stage}/stop-status", f"rm {stage}/pause-state-check")
        machine.wait_until_succeeds(f"test -s {stage}/stop-status")
        assert_full_match(f"cat {stage}/restart-status", "1\n")
        assert int(succeed(f"cat {stage}/stop-status")) != 0
        assert succeed(f"systemctl list-jobs --no-legend cdk-mintd.service | grep -w {action}").split()[0] == job
        succeed(f"rm {stage}/reject-restart {stage}/state-checked")
        machine.wait_until_succeeds(f"test -d {stage}/.next")
        succeed(f"rm {pause_copy}", "systemctl start cdk-mintd-backup")
        ready()

    for action in ["cancel", "timeout"]:
        if action == "timeout":
            machine.succeed(
                "mkdir -p /run/systemd/system/cdk-mintd-backup.service.d\n"
                "printf '[Service]\\nTimeoutStartSec=3s\\n' > /run/systemd/system/cdk-mintd-backup.service.d/timeout.conf\n"
                "systemctl daemon-reload"
            )
        succeed(f"touch {barrier}", "systemctl start --no-block cdk-mintd-backup")
        machine.wait_until_succeeds("test $(systemctl show -P SubState cdk-mintd) = stop")
        machine.fail(f"test -e {stage}/.next")
        if action == "cancel":
            succeed("systemctl stop --no-block cdk-mintd-backup")
        else:
            machine.wait_until_succeeds("test $(systemctl show -P Result cdk-mintd-backup) = timeout")
        succeed(f"rm {barrier}")
        ready()
        machine.fail(f"test -e {stage}/current")
        machine.fail(f"test -e {stage}/.next")
        if action == "timeout":
            succeed("rm /run/systemd/system/cdk-mintd-backup.service.d/timeout.conf", "systemctl daemon-reload")
        succeed("systemctl reset-failed cdk-mintd-backup cdk-mintd")

    # A stop arriving either before the restart transaction or during its stop
    # half must win, including stops of dependencies pulled in by the mint.
    for stop_first in [False, True]:
        for target in ["cdk-mintd", backend, "bitcoind"]:
            succeed(f"touch {barrier} {pause_copy}", f"rm -f {stage}/restart-status")
            if stop_first:
                succeed("systemctl start cdk-shutdown-blocker", f"touch {stage}/pause-state-check")
            succeed("systemctl start --no-block cdk-mintd-backup")
            if stop_first:
                machine.wait_until_succeeds(f"test -e {stage}/state-checked")
            else:
                machine.wait_until_succeeds("test $(systemctl show -P SubState cdk-mintd) = stop")
            machine.fail(f"test -e {stage}/.next")
            succeed(f"systemctl stop --no-block {target}")
            machine.wait_until_succeeds(f"systemctl list-jobs --no-legend {target}.service | grep -w stop")
            if stop_first:
                succeed(f"rm {stage}/pause-state-check")
                machine.wait_until_succeeds(f"test -s {stage}/restart-status")
                assert int(succeed(f"cat {stage}/restart-status")) != 0
            succeed(f"rm {barrier}", f"systemctl stop {target}")
            machine.wait_until_succeeds(f"test -d {stage}/.next")
            assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
            succeed(f"rm {pause_copy}", "systemctl start cdk-mintd-backup")
            assert_full_match(f"systemctl show -P ActiveState {target}", "inactive\n")
            assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
            if stop_first:
                succeed(f"rm {stage}/state-checked")
            succeed("systemctl reset-failed cdk-mintd cdk-mintd-backup",
                    f"systemctl start bitcoind {backend} cdk-mintd")
            ready()

    # If the stop finishes before the restart is submitted, there is no job to
    # conflict with. try-restart must still leave the mint and backends stopped.
    for target in ["cdk-mintd", backend, "bitcoind"]:
        succeed(f"touch {stage}/pause-state-check {pause_copy}",
                "systemctl start --no-block cdk-mintd-backup")
        machine.wait_until_succeeds(f"test -e {stage}/state-checked")
        succeed(f"systemctl stop {target}", f"rm {stage}/pause-state-check")
        machine.wait_until_succeeds(f"test -d {stage}/.next")
        succeed(f"rm {pause_copy}", "systemctl start cdk-mintd-backup")
        assert_full_match(f"systemctl show -P ActiveState {target}", "inactive\n")
        assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
        succeed(f"rm {stage}/state-checked", "systemctl reset-failed cdk-mintd cdk-mintd-backup",
                f"systemctl start bitcoind {backend} cdk-mintd")
        ready()
    succeed(f"rm {stage}/restart-status {stage}/stop-status",
            "rm /run/systemd/system/cdk-mintd.service.d/slow-stop.conf /run/systemd/system/cdk-shutdown-blocker.service",
            "systemctl daemon-reload")
