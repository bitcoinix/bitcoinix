# Impure: Stops electrs
# Stop electrs from spamming the test log with 'waiting for 0 blocks to download' messages
@test("stop-electrs")
def test_stop_electrs():
    succeed("systemctl stop electrs")


# Impure: stops, starts and restarts bitcoind and its dependents
@test("restart-bitcoind")
def test_restart_bitcoind():
    # lnd, electrs and clightning `require` bitcoind and are `wantedBy` it.
    # A deploy that changes the bitcoind unit stops bitcoind and starts it
    # again. The stop propagates to the dependents. The start must bring them
    # back. An explicit stop must keep everything down.
    dependents = [unit for unit in ["lnd", "clightning", "electrs"] if unit in enabled_tests]

    def state(unit):
        return succeed(f"systemctl show -P ActiveState {unit}").strip()

    def inactive_since(unit):
        return succeed(f"systemctl show -P InactiveEnterTimestampMonotonic {unit}").strip()

    def wait_for_bitcoind():
        machine.wait_until_succeeds("runuser -u operator -- bitcoin-cli getnetworkinfo")

    # 0. 'backups' and 'stop-electrs' may have left units down. Start each one
    # explicitly so that only the steps below rely on `wantedBy`.
    succeed("systemctl start bitcoind")
    wait_for_bitcoind()
    for unit in dependents:
        succeed(f"systemctl start {unit}")
        machine.wait_for_unit(unit)

    # A dependent can end up `failed` instead of `inactive` when it hits its
    # stop timeout (clightning with clboss has TimeoutStopSec=500ms here).
    # Either way it's down, and a stop job never triggers Restart=.
    stopped = "inactive|failed"

    # 1. An explicit stop propagates and sticks.
    succeed("systemctl stop bitcoind")
    for unit in dependents:
        machine.wait_until_succeeds(f"[[ $(systemctl show -P ActiveState {unit}) =~ ^({stopped})$ ]]")
    stopped_at = {unit: inactive_since(unit) for unit in ["bitcoind"] + dependents}
    # Longer than every dependent's RestartSec (10s), so a restart that pulled
    # bitcoind back up would show here.
    machine.sleep(25)
    for unit, since in stopped_at.items():
        assert re.fullmatch(stopped, state(unit)), f"{unit} came back after an explicit stop"
        assert inactive_since(unit) == since, f"{unit} was restarted after an explicit stop"

    # 2. The start half of a deploy brings the dependents back.
    # `wait_for_unit` raises on `failed` even with a start job queued, so clear
    # that state first. `inactive` with no job queued still raises.
    succeed(f"systemctl reset-failed {' '.join(dependents)}")
    succeed("systemctl start bitcoind")
    wait_for_bitcoind()
    for unit in dependents:
        machine.wait_for_unit(unit)
    # Give them time to connect, then check they are still up.
    machine.sleep(15)
    for unit in dependents:
        machine.wait_for_unit(unit)

    # 3. A plain restart propagates and everything is up afterwards.
    succeed("systemctl restart bitcoind")
    wait_for_bitcoind()
    for unit in dependents:
        machine.wait_for_unit(unit)


# Impure: restarts services
@test("config-replace")
def test_config_replace():
    # Services write their config at start, and the config dirs are writable by
    # the operator (bitcoind, clightning) or the service user.
    # Test that symlinks to files and directories are replaced by regular files
    # with the expected owner and mode, without changing the symlink targets.
    for data in test_data["config-replace"]:
        unit, file, user, planter = data["unit"], data["file"], data["user"], data["planter"]
        with machine.nested(f"config file: {file}"):
            # The unit might still be restarting after the preceding 'restart-bitcoind' test
            succeed(f"systemctl start {unit}")
            orig = f"{file}.orig"
            # The target must be inside the config dir, which is the only path the
            # service can write (ProtectSystem, ProtectHome, PrivateTmp)
            target = f"{os.path.dirname(file)}/config-replace-target"
            for target_type in ("file", "directory"):
                with machine.nested(f"symlink to {target_type}"):
                    # A started unit may still be reading its config. Stop it
                    # before planting the symlink for the next start.
                    succeed(f"systemctl stop {unit}")
                    if target_type == "file":
                        # Identical content also covers services that skip an
                        # update when the content is unchanged.
                        succeed(
                            f"cat {file} > {target}",
                            f"chown {planter} {target}",
                            f"chmod 666 {target}",
                        )
                        contents = f"cat {target}"
                    else:
                        # Without install -T, install writes inside this writable
                        # directory and leaves the config symlink in place.
                        succeed(f"install -d -o {user} -m 700 {target}")
                        contents = f"find {target} -mindepth 1 -print"
                    metadata = f"stat -c '%i %U %G %a %s %y %z' {target}"
                    before_contents = succeed(contents)
                    before_metadata = succeed(metadata)
                    succeed(
                        f"runuser -u {planter} -- sh -c 'mv {file} {orig} && ln -s {target} {file}'",
                        f"systemctl start {unit}",
                    )
                    machine.wait_for_unit(unit)
                    assert_file_metadata(file, owner=user, mode=data["mode"], file_type="regular file")
                    assert_full_match(contents, re.escape(before_contents))
                    assert_full_match(metadata, re.escape(before_metadata))
                    succeed(f"rm {orig}", f"{'rm' if target_type == 'file' else 'rmdir'} {target}")


# Impure: restarts lnd. Runs after `regtest`, so lnd is synced.
@test("lnd-restart-on-clean-exit")
def test_lnd_restart_on_clean_exit():
    # `lncli stop` shuts lnd down cleanly (exit status 0), like lnd's chain
    # backend health check does when bitcoind stays unreachable. lnd must come
    # back on its own (`Restart = "always"`).
    #
    # Pause the charge-lnd timer first: charge-lnd `requires` lnd, so a timer
    # tick during this test would start lnd itself and hide a missing
    # `Restart=`. RTL only `wants` lnd and keeps running while lnd is down.
    timers = ["charge-lnd.timer"] if "charge-lnd" in enabled_tests else []
    for unit in timers:
        succeed(f"systemctl stop {unit}")
    assert_running("lnd")
    before = succeed("systemctl show -P InvocationID lnd").strip()
    succeed("runuser -u operator -- lncli stop")
    # Right after `lncli stop`, lnd may still be active (shutting down).
    # Poll for a new invocation instead of polling `is-active`.
    machine.wait_until_succeeds(f"[[ $(systemctl show -P InvocationID lnd) != '{before}' ]]")
    machine.wait_for_unit("lnd")
    machine.wait_until_succeeds("runuser -u operator -- lncli getinfo")
    for unit in timers:
        succeed(f"systemctl start {unit}")
