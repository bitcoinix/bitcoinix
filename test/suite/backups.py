# Impure: stops bitcoind (and dependent services)
@test("backups")
def test_backups():
    # For testing that bitcoind wallets are backed up
    succeed("bitcoin-cli -named createwallet wallet_name=test blank=true >/dev/null")
    run_duplicity = "export $(cat /secrets/backup-encryption-env); duplicity"

    def backup_files():
        return succeed(f"{run_duplicity} list-current-files file:///var/lib/localBackups")

    # Leave a database, a recovery file and a block on an inactive network.
    inactive = next(net for net in ("signet", "testnet4") if net != test_data["bitcoinNetwork"])
    old_cln = f"{test_data['clightning']['dataDir'].lstrip('/')}/{inactive}"
    old_blocks = f"{test_data['backups']['bitcoindDir'].lstrip('/')}/{inactive}/blocks"
    old_db = f"{old_cln}/lightningd.sqlite3"
    old_secret = f"{old_cln}/hsm_secret"
    old_block = f"{old_blocks}/backup-test-block"
    succeed(f"mkdir -p /{old_cln} /{old_blocks}",
            f"touch /{old_db} /{old_db}-wal /{old_secret} /{old_block}")

    # Restoring a copy of a channel database can lose all funds in its channels.
    # Each entry has a database that exists and the path the backup must leave out.
    channel_dbs = [
        ("lnd", "var/lib/lnd/graph/mainnet/channel.db", "var/lib/lnd/graph"),
        ("clightning", "var/lib/clightning/bitcoin/lightningd.sqlite3",
         "var/lib/clightning/bitcoin/lightningd.sqlite3"),
    ]

    def assert_no_channel_dbs(backup):
        for test, file, excluded in channel_dbs:
            if test in enabled_tests:
                succeed(f"test -e /{file}")
                if excluded in backup:
                    raise Exception(f"Backup includes '{excluded}'.")

    wallet_copies = "var/lib/bitcoind/wallet-backups"

    def copy_name(wallet):
        return f"wallet-{hashlib.sha256(wallet.encode()).hexdigest()}.dat"

    wallet_copy = f"{wallet_copies}/{copy_name('test')}"

    def assert_wallet_copy(backup):
        if wallet_copy not in backup:
            raise Exception("Backup has no copy of the loaded bitcoind wallet 'test'.")
        # The index maps each copy to its wallet name
        index = succeed_json(f"cat /{wallet_copies}/wallet-names.json")
        assert index == {copy_name("test"): "test"}, index

    # While bitcoind and the Lightning daemons run, the backup has a consistent copy
    # of each loaded wallet and no channel database
    succeed("systemctl start duplicity")
    live_files = backup_files()
    assert_wallet_copy(live_files)
    assert_no_channel_dbs(live_files)
    assert old_db not in live_files, old_db  # Also matches its WAL
    assert old_secret in live_files, old_secret
    assert (old_block in live_files) == test_data["backups"]["with-bulk-data"], old_block

    # The next backup replaces the copy and keeps no copy from an earlier backup.
    # It keeps other files, like those of a wallet named `wallet-backups`.
    stale_copy = f"{wallet_copies}/{copy_name('gone')}"
    other_files = [f"/{wallet_copies}/{name}" for name in ["wallet.dat", "notes.txt"]]
    for file in [f"/{stale_copy}", *other_files]:
        succeed(f"install -o bitcoin -g bitcoin -m 600 /dev/null {file}")
    succeed("systemctl start duplicity")
    live_files = backup_files()
    assert_wallet_copy(live_files)
    for file in [stale_copy, f"{wallet_copy}.tmp"]:
        if file in live_files:
            raise Exception(f"Backup includes '{file}'.")
    succeed(*[f"test -f {file}" for file in other_files])
    succeed(*[f"rm {file}" for file in other_files])

    succeed("systemctl stop bitcoind")
    assert_matches("systemctl show -p ExecMainStatus --value bitcoind", "^0$")
    # lnd writes its static channel backup only once it's synced to the chain, which
    # a test node without blocks never is. Add a stand-in to check that it's backed up.
    lnd_scb = "/var/lib/lnd/chain/bitcoin/mainnet/channel.backup"
    add_scb_stand_in = "lnd" in enabled_tests and machine.execute(f"test -e {lnd_scb}")[0] != 0
    if add_scb_stand_in:
        succeed(f"install -o lnd -g lnd -m 600 /dev/null {lnd_scb}")
    succeed("systemctl start duplicity")
    machine.wait_until_succeeds(log_has_string("duplicity", "duplicity.service: Deactivated successfully."))
    # Files in backup and /var/lib should be identical
    assert_matches(
        f"{run_duplicity} verify --archive-dir /var/lib/duplicity file:///var/lib/localBackups /var/lib",
        "no sync needed",
    )
    # Backup should include important files
    files = [
        ("bitcoind", "var/lib/bitcoind/test/wallet.dat"),
        ("clightning", "var/lib/clightning/bitcoin/hsm_secret"),
        ("clightning", "var/lib/clightning/bitcoin/emergency.recover"),
        ("lnd", "var/lib/lnd/lnd-seed-mnemonic"),
        ("lnd", "var/lib/lnd/chain/bitcoin/mainnet/channel.backup"),
        ("btcpayserver", "var/backup/postgresql/btcpaydb.sql.gz"),
        # Holds the private keys of BTCPay hot wallets
        ("btcpayserver", "var/backup/postgresql/nbxplorer.sql.gz"),
    ]
    actual_files = backup_files()

    def assert_file_exists(file):
        if file not in actual_files:
            raise Exception(f"Backup file '{file}' is missing.")

    for test, file in files:
        if test in enabled_tests:
            assert_file_exists(file)

    assert_no_channel_dbs(actual_files)
    # A stopped bitcoind writes no wallet, so the backup has only the wallet files
    if wallet_copy in actual_files:
        raise Exception("Backup has a wallet copy although bitcoind was stopped.")

    if add_scb_stand_in:
        succeed(f"rm {lnd_scb}")

    if "btcpayserver" in enabled_tests:
        # The dump includes the table where NBXplorer stores hot wallet keys
        succeed("zgrep -q 'CREATE TABLE public.nbxv1_metadata' /var/backup/postgresql/nbxplorer.sql.gz")

    assert_file_exists("secrets/lnd-wallet-password")

    if "btcpayserver" in enabled_tests:
        # A failed database dump fails the backup, but all other files are still backed up
        psql = "runuser -u postgres -- psql -c"
        succeed(f"{psql} 'ALTER DATABASE btcpaydb WITH ALLOW_CONNECTIONS false'")
        machine.fail("systemctl start duplicity")
        succeed(f"{psql} 'ALTER DATABASE btcpaydb WITH ALLOW_CONNECTIONS true'")
        succeed(log_has_string("duplicity", "postgresqlBackup-btcpaydb.service"))
        actual_files = backup_files()
        if "var/backup/postgresql/btcpaydb.sql.gz" in actual_files:
            raise Exception("Backup includes a btcpaydb dump although the dump failed.")
        assert_file_exists("secrets/lnd-wallet-password")

        # The next backup includes the database again
        succeed("systemctl start duplicity")
        actual_files = backup_files()
        assert_file_exists("var/backup/postgresql/btcpaydb.sql.gz")
