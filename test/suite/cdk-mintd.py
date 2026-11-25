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
    machine.fail(f"test -d {data['dataDir']}/logs")
    guard = "/var/lib/nixos/cdk-mintd/initialized"
    assert_full_match(f"stat -c '%U' {guard}", "root\n")
    machine.fail(f"runuser -u {data['user']} -- rm -f {guard}")

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

    # Losing the database must fail closed even if nix-config survives. Keep the
    # original state and restore it afterwards, as a real recovery would do.
    directory = data["dataDir"]
    succeed("systemctl stop cdk-mintd", f"mv {directory} {directory}.saved",
            f"install -d -o {data['user']} -g {data['group']} -m 700 {directory}",
            f"cp -a {directory}.saved/nix-config {directory}/")
    machine.fail("systemctl start cdk-mintd")
    succeed("journalctl -u cdk-mintd | grep -F 'Refusing to recreate an initialized mint'",
            "systemctl stop cdk-mintd", f"rm -rf {directory}",
            f"mv {directory}.saved {directory}", "systemctl reset-failed cdk-mintd",
            "systemctl start cdk-mintd")
    machine.wait_until_succeeds(f"curl -fsS {url}/info")
    assert succeed_json(f"curl -fsS {url}/keys") == keys
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


# Mines blocks after the common regtest checks have checked the fixture height.
@test("cdk-mintd-onchain")
def test_cdk_mintd_onchain():
    data = test_data["cdk-mintd"]
    url = f"http://{ip('cdk-mintd')}:{data['port']}/v1"
    # Inspect the actual generated TOML for IPv6 endpoints. The LND module's own
    # IPv6 listener support is covered separately by its endpoint changes.
    import tomllib
    config_file = re.search(r"config init --new-mint --file (\S+)", test_data["cdk-mintd-ipv6-pre-start"])
    assert config_file is not None
    ipv6 = tomllib.loads(succeed(f"cat {config_file.group(1)}"))
    assert ipv6["info"]["listen_host"] == "[::]", ipv6
    assert ipv6["lnd"]["address"] == "https://[::1]:10009", ipv6
    assert ipv6["bdk"]["bitcoind_rpc_host"] == "[::1]", ipv6
    assert ipv6["info"]["logging"]["output"] == "stderr", ipv6
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


@test("cdk-mintd-backup")
def test_cdk_mintd_backup():
    data = test_data["cdk-mintd"]
    directory, user, group = data["dataDir"], data["user"], data["group"]
    url = f"http://{ip('cdk-mintd')}:{data['port']}/v1"
    stage = "/var/lib/cdk-mintd-backup"
    current = f"{stage}/current"
    runtime = "/run/cdk-mintd-backup"
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
            f"mv {directory} {directory}.before-restore",
            f"install -d -o {user} -g {group} -m 700 {directory}")
    succeed(f"systemctl restart {data['backend']}")
    machine.fail("systemctl start cdk-mintd")
    machine.fail(f"test -e {directory}/cdk-mintd.sqlite")
    succeed(f"umask 077; setpriv --reuid={user} --regid={group} --init-groups -- "
            f"tar --no-same-owner --no-same-permissions -xf - -C {directory} < {restored}/data.tar",
            f"install -o {user} -g {group} -m 440 {restored}/seed {data['seedFile']}",
            f"install -o {user} -g {group} -m 440 {restored}/bdk-mnemonic {data['mnemonicFile']}")
    assert_full_match(f"stat -c '%a' {directory}/wide-mode", "700\n")
    assert_full_match(f"runuser -u {user} -- sqlite3 {directory}/cdk-mintd.sqlite 'PRAGMA integrity_check'", "ok\n")
    assert_full_match(f"runuser -u {user} -- sqlite3 {directory}/bdk_wallet/bdk_wallet.sqlite 'PRAGMA integrity_check'", "ok\n")
    assert_full_match(f"readlink {directory}/root-link", "/root/cdk-backup-canary\n")
    assert_full_match("cat /root/cdk-backup-canary", "root-secret\n")
    assert succeed(f"sha256sum {data['seedFile']}").split()[0] == seed_hash
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
    machine.wait_until_succeeds(f"test -e {runtime}/restart && test -d {stage}/.next")
    succeed(f"rm {directory}/pause-backup", "timeout 30 systemctl start cdk-mintd-backup")
    assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
    succeed("rm /run/cdk-start-barrier")
    ready()
    succeed("rm /run/systemd/system/cdk-mintd.service.d/barrier.conf",
            "systemctl daemon-reload")

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
    machine.wait_until_succeeds(f"test -e {runtime}/in-progress && test -d {stage}/.next")
    succeed(f"systemctl restart {data['backend']}", "systemctl start cdk-mintd")
    assert_full_match("systemctl show -P ActiveState cdk-mintd", "inactive\n")
    succeed("systemctl stop cdk-mintd-backup")
    ready()
    machine.fail(f"test -e {runtime}/in-progress")
    machine.fail(f"test -e {stage}/.next")
    machine.fail(f"test -e {current}")
    succeed(f"rm {directory}/pause-backup", "systemctl reset-failed cdk-mintd-backup",
            "systemctl start duplicity")
    ready()
    assert f"{current.lstrip('/')}/data.tar" in files()
