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


# Impure: restarts clightning
@test("clnrest-admin-rune")
def test_clnrest_admin_rune():
    # Earlier versions installed an empty or `null` admin rune when `createrune`
    # failed, and later starts kept that file. A start must replace such a file,
    # but never a valid rune.
    data = test_data["clnrest-admin-rune"]
    rune_file = data["file"]
    getinfo = f"https://{ip('clightning')}:{data['port']}/v1/getinfo"

    def clnrest_accepts(rune):
        status, _ = machine.execute(
            f"curl -fsS --max-time 5 --insecure --header 'rune: {rune}' -X POST {getinfo}"
        )
        return status == 0

    def start_with(contents):
        """Start clightning with `contents` in the rune file, return the rune afterwards"""
        succeed("systemctl stop clightning")
        if contents is not None:
            succeed(f"printf %s {shlex.quote(contents)} > {rune_file}")
        # Returns after `postStart`, which creates the rune
        succeed("systemctl start clightning")
        rune = succeed(f"cat {rune_file}").rstrip("\n")
        assert_file_metadata(rune_file, owner=data["user"], mode="640", file_type="regular file")
        succeed(f"! test -e {rune_file}.tmp")
        assert clnrest_accepts(rune), f"clnrest rejects the rune in {rune_file}: {rune!r}"
        return rune

    # The unit might still be restarting after the preceding tests
    succeed("systemctl start clightning")
    machine.wait_for_unit("clightning")
    # Otherwise, `clnrest_accepts` wouldn't check the rune
    assert not clnrest_accepts("null"), "clnrest accepts the rune 'null'"

    rune = succeed(f"cat {rune_file}").rstrip("\n")
    assert start_with(None) == rune, f"A start replaced the valid rune in {rune_file}"
    # The files that earlier versions installed when `createrune` failed
    for contents in ("\n", "null\n"):
        with machine.nested(f"rune file contents: {contents!r}"):
            rune = start_with(contents)

    if rtl_file := data["rtlFile"]:
        # RTL stopped with clightning, and clightning's start started it again,
        # so RTL copied the new rune
        machine.wait_for_unit("rtl")
        assert_full_match(f"cat {rtl_file}", re.escape(f'LIGHTNING_RUNE="{rune}"\n'))


# Impure: stops, starts and terminates lnd and clightning
@test("rtl-stops-with-backend")
def test_rtl_stops_with_backend():
    # RTL sends the lnd admin macaroon and the clightning admin rune to its
    # backends without checking their certificate. So it must stop with a
    # backend's unit, and start again only after the backend's start finished.
    data = test_data["rtl-credentials"]
    backends = [unit for unit in ("lnd", "clightning") if data[unit]]
    # RestartSec of lnd, clightning and RTL
    restart_sec = 10
    # See `restart-bitcoind` for why a stopped unit can be `failed`
    stopped = "inactive|failed"

    def show(unit, prop):
        return succeed(f"systemctl show -P {prop} {unit}").strip()

    def assert_rtl_started_after(backend):
        machine.wait_for_unit(backend)
        machine.wait_for_unit("rtl")
        rtl_start = int(show("rtl", "ExecMainStartTimestampMonotonic"))
        backend_ready = int(show(backend, "ActiveEnterTimestampMonotonic"))
        assert rtl_start >= backend_ready, f"RTL started before {backend} was ready"

    # charge-lnd `requires` lnd, so a timer tick would start lnd, and RTL with it
    timers = ["charge-lnd.timer"] if "charge-lnd" in enabled_tests else []
    for unit in timers:
        succeed(f"systemctl stop {unit}")
    # The preceding tests may have left units down
    succeed(f"systemctl start {' '.join(backends)} rtl")

    for backend in backends:
        with machine.nested(f"backend: {backend}"):
            # 1. An explicit stop stops RTL first, and RTL stays down.
            succeed(f"systemctl stop {backend}")
            assert show("rtl", "ActiveState") == "inactive", f"RTL runs without {backend}"
            # Longer than RestartSec, so a restart of RTL would show here
            machine.sleep(restart_sec + 5)
            assert re.fullmatch(stopped, show(backend, "ActiveState")), f"{backend} came back"
            assert show("rtl", "ActiveState") == "inactive", f"RTL came back without {backend}"

            # 2. Starting the backend starts RTL, after the backend is ready.
            succeed(f"systemctl start {backend}")
            assert_rtl_started_after(backend)

            # 3. When the backend exits by itself, with no stop job, RTL stops
            # with it. lnd exits cleanly on SIGTERM, so the later
            # `assert_no_failure` checks of lnd still pass. clightning's exit
            # can fail, see below. No later test checks clightning for failures.
            backend_before = show(backend, "InvocationID")
            rtl_before = show("rtl", "InvocationID")
            succeed(f"systemctl kill -s TERM {backend}")
            if backend == "lnd":
                # `Restart = "always"` brings lnd back, and lnd starts RTL once it's ready
                machine.wait_until_succeeds(
                    f"[[ $(systemctl show -P InvocationID {backend}) != '{backend_before}' ]]"
                )
            else:
                # clightning only restarts on failure. With clboss, a torified
                # `dig` ignores SIGTERM, so the exit can hit the stop timeout and
                # fail. Then clightning goes from `failed` to `activating` in one
                # step and restarts after RestartSec, so polling `ActiveState`
                # alone can miss the stop. Wait for either outcome.
                machine.wait_until_succeeds(
                    f"[[ $(systemctl show -P InvocationID {backend}) != '{backend_before}' ]] || "
                    f"[[ $(systemctl show -P ActiveState {backend}) =~ ^({stopped})$ ]]"
                )
                # Also fine during or after clightning's own restart
                succeed(f"systemctl start {backend}")
            assert_rtl_started_after(backend)
            assert show("rtl", "InvocationID") != rtl_before, "RTL was not restarted"
            if backend == "lnd":
                # Nothing that RTL adds may start lnd before its RestartSec.
                # `wantedBy = [ "lnd.service" ]` on RTL did, because lnd sends
                # STOPPING=1 as it shuts down.
                restart_delay = (int(show(backend, "ExecMainStartTimestampMonotonic"))
                                 - int(show(backend, "InactiveEnterTimestampMonotonic")))
                assert restart_delay >= (restart_sec - 1) * 1_000_000, \
                    f"lnd restarted {restart_delay / 1_000_000:.1f} s after it exited"
            # RTL must stop when the backend exits, not after a restart delay.
            # Half of RestartSec leaves time for RTL's own stop.
            delay = (int(show("rtl", "InactiveEnterTimestampMonotonic"))
                     - int(show(backend, "InactiveEnterTimestampMonotonic")))
            assert delay < restart_sec * 1_000_000 / 2, f"RTL kept running without {backend}"

    if len(backends) == 2:
        # 4. While one backend is stopped, the other's start doesn't start it or
        # RTL: the hook doesn't pull in RTL's backends, and systemd refuses to
        # start RTL while a backend that it's bound to is down.
        since = succeed("date +%s").strip()
        succeed("systemctl stop clightning")
        succeed("systemctl restart lnd")
        # lnd's start queued a start of RTL, which systemd refused
        machine.wait_until_succeeds(
            f"journalctl -u rtl --since @{since} --grep"
            " 'Bound to unit clightning.service, but unit isn'"
        )
        assert re.fullmatch(stopped, show("clightning", "ActiveState")), "lnd's start started clightning"
        assert show("rtl", "ActiveState") == "inactive", "RTL runs without clightning"
        succeed("systemctl start clightning")
        assert_rtl_started_after("clightning")

    for unit in timers:
        succeed(f"systemctl start {unit}")


# Impure: restarts lnd. Runs after `regtest`, so lnd is synced.
@test("lnd-restart-on-clean-exit")
def test_lnd_restart_on_clean_exit():
    # `lncli stop` shuts lnd down cleanly (exit status 0), like lnd's chain
    # backend health check does when bitcoind stays unreachable. lnd must come
    # back on its own (`Restart = "always"`).
    #
    # Pause the charge-lnd timer first: charge-lnd `requires` lnd, so a timer
    # tick during this test would start lnd itself and hide a missing
    # `Restart=`. RTL is bound to lnd and stops with it. Only lnd's own start
    # starts RTL again, so RTL never starts lnd here.
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
