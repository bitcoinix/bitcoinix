"""Exercise the assembled suite's runner without starting a VM."""

from contextlib import nullcontext
from pathlib import Path
import sys
import unittest


suite_path = Path(sys.argv.pop(1))
suite = compile(suite_path.read_text(), str(suite_path), "exec")


class MachineStub:
    def __init__(self):
        self.connected = False

    def connect(self):
        self.connected = True

    def nested(self, message):
        return nullcontext()


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.machine = MachineStub()
        self.context = {
            "machine": self.machine,
            "enabled_tests": set(),
            "test_data": {},
        }
        exec(suite, self.context)
        self.calls = []
        # Reverse registration order to ensure file order cannot reorder tests.
        self.context["tests"] = {
            name: lambda name=name: self.calls.append(name)
            for name in reversed(self.context["tests"])
        }

    def test_phase_order_preserves_service_dependencies(self):
        expected = [
            "electrs", "stop-electrs", "netns-isolation", "hardening-ro-paths",
            "backups", "restart-bitcoind", "config-replace", "regtest",
            "lnd-restart-on-clean-exit", "trustedcoin", "setup-secrets",
            "setup-secrets-supplied",
        ]
        self.context["enabled_tests"] = set(expected)
        self.context["nb_run_tests"]()
        self.assertTrue(self.machine.connected)
        self.assertEqual(self.calls, expected)

    def test_unknown_test_fails_before_connecting(self):
        self.context["enabled_tests"] = {"unknown"}
        with self.assertRaisesRegex(RuntimeError, "enabled but not defined.*unknown"):
            self.context["nb_run_tests"]()
        self.assertFalse(self.machine.connected)
        self.assertEqual(self.calls, [])

    def test_selection_skips_disabled_tests(self):
        self.context["enabled_tests"] = {"bitcoind"}
        self.context["nb_run_tests"]()
        self.assertEqual(self.calls, ["bitcoind"])

    def test_custom_tests_follow_builtins_in_registration_order(self):
        for name in ["custom-z", "custom-a", "custom-disabled"]:
            self.context["test"](name)(lambda name=name: self.calls.append(name))
        self.context["enabled_tests"] = {"custom-z", "custom-a", "backups"}
        self.context["nb_run_tests"]()
        self.assertEqual(self.calls, ["backups", "custom-z", "custom-a"])

    def test_duplicate_registration_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Duplicate test: bitcoind"):
            self.context["test"]("bitcoind")(lambda: None)

    def test_missing_body_is_rejected_even_when_disabled(self):
        del self.context["tests"]["backups"]
        with self.assertRaisesRegex(RuntimeError, "undefined=\\['backups'\\]"):
            self.context["validate_test_plan"]()

    def test_new_builtin_requires_a_place_in_the_plan(self):
        self.context["test"]("new-builtin")(lambda: None)
        with self.assertRaisesRegex(RuntimeError, "unplanned=\\['new-builtin'\\]"):
            self.context["validate_test_plan"]()

    def test_duplicate_plan_entry_is_rejected(self):
        self.context["TEST_PHASES"] += (("duplicate", ("bitcoind",)),)
        with self.assertRaisesRegex(RuntimeError, "Duplicate test in TEST_PHASES"):
            self.context["validate_test_plan"]()

    def test_interactive_run_can_select_a_disabled_test(self):
        self.context["run_test"]("bitcoind")
        self.assertEqual(self.calls, ["bitcoind"])


if __name__ == "__main__":
    unittest.main()
