"""Small runner for the NixOS driver; see README.md for the phase contract."""

# Keep this order independent of the files containing the test bodies.
# The initial split preserves the order of the former monolithic suite.
TEST_PHASES = (
    ("services", (
        "security",
        "secrets-no-argv",
        "bitcoind",
        "bitcoind-rest",
        "rpc-whitelist",
        "electrs",
        "fulcrum",
        "stop-electrs",
        "clightning",
        "lnd",
        "lnd-macaroons",
        "lndconnect-onion-lnd",
        "lnconnect-onion-clnrest",
        "lnconnect-clnrest-cert",
        "lndconnect-local-bind",
        "charge-lnd",
        "btcpayserver",
        "rtl",
        "rtl-credentials",
        "mempool",
        "nodeinfo",
        "secure-node",
        "onion-addresses",
    )),
    ("network-and-hardening", (
        "netns-isolation",
        "hardening-ro-paths",
    )),
    ("disruptive", (
        "backups",
        "restart-bitcoind",
        "config-replace",
    )),
    ("post-restart", (
        "regtest",
        "lnd-restart-on-clean-exit",
        "trustedcoin",
    )),
    ("secrets", (
        "setup-secrets",
        "setup-secrets-supplied",
    )),
)

tests = {}


def test(name):
    def register(fn):
        if name in tests:
            raise RuntimeError(f"Duplicate test: {name}")
        tests[name] = fn
        return fn
    return register


def validate_test_plan():
    # Called after loading the built-in suite, before extraTestScript.
    planned = [name for _, names in TEST_PHASES for name in names]
    if len(planned) != len(set(planned)):
        raise RuntimeError("Duplicate test in TEST_PHASES")
    if set(planned) != set(tests):
        raise RuntimeError(
            f"Test plan mismatch: undefined={sorted(set(planned) - set(tests))}, "
            f"unplanned={sorted(set(tests) - set(planned))}"
        )


def selected_test_phases():
    undefined = enabled_tests - tests.keys()
    if undefined:
        raise RuntimeError(f"The following tests are enabled but not defined: {sorted(undefined)}")
    planned = {name for _, names in TEST_PHASES for name in names}
    # Preserve extraTestScript's registration order and its position after the
    # built-in tests. These custom tests may see stopped or restarted services.
    extra = tuple(name for name in tests if name not in planned)
    return [
        (phase, [name for name in names if name in enabled_tests])
        for phase, names in (*TEST_PHASES, ("extra", extra))
        if any(name in enabled_tests for name in names)
    ]


# `run_tests` is already defined by the NixOS test driver.
def nb_run_tests():
    phases = selected_test_phases()
    machine.connect()  # Visually separate boot output from the test output
    for phase, names in phases:
        with machine.nested(f"phase: {phase}"):
            for name in names:
                with machine.nested(f"test: {name}"):
                    tests[name]()


def run_test(name):
    tests[name]()
