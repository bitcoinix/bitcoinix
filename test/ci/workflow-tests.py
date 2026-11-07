"""Exercise CI skip decisions without GitHub, network access, or VM builds."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

workflow = yaml.safe_load(Path(sys.argv.pop(1)).read_text())
scripts = Path(sys.argv.pop(1)).resolve()


class WorkflowTests(unittest.TestCase):
    def test_gate(self):
        gate = workflow['jobs']['ci_gate']['steps'][0]['run']
        normal = dict.fromkeys([
            'CHANGES', 'BUILD_TEST_DRIVERS', 'TEST_SCENARIO', 'CHECK_FLAKE',
            'SHELLCHECK', 'NIXOS_SEARCH', 'RELEASE_TOOLING', 'DEPLOYMENT_EXAMPLES',
        ], 'success')
        normal.update(DOCS_ONLY='false', RUN_SCENARIOS='true',
                      EVENT_NAME='pull_request', CACHE_FLAKE_INFO='skipped')
        cached = normal | dict(RUN_SCENARIOS='false', TEST_SCENARIO='skipped')
        docs = normal | dict(DOCS_ONLY='true', RUN_SCENARIOS='') | dict.fromkeys([
            'BUILD_TEST_DRIVERS', 'TEST_SCENARIO', 'NIXOS_SEARCH', 'DEPLOYMENT_EXAMPLES',
        ], 'skipped')
        master = normal | dict(EVENT_NAME='push', CACHE_FLAKE_INFO='success')
        for valid in [normal, cached, docs, master]:
            self.assertEqual(self.gate_result(gate, valid), 0)
            # Every job failure/cancellation must fail the gate, even for docs PRs.
            for key in normal:
                if key in ['DOCS_ONLY', 'RUN_SCENARIOS', 'EVENT_NAME']:
                    continue
                for result in ['failure', 'cancelled']:
                    with self.subTest(key=key, result=result, valid=valid):
                        self.assertNotEqual(self.gate_result(gate, valid | {key: result}), 0)
        for overrides in [dict(CHANGES='skipped'), dict(DOCS_ONLY=''),
                          dict(TEST_SCENARIO='skipped'), dict(BUILD_TEST_DRIVERS='skipped'),
                          dict(RUN_SCENARIOS=''), dict(NIXOS_SEARCH='skipped'),
                          dict(DEPLOYMENT_EXAMPLES='skipped')]:
            self.assertNotEqual(self.gate_result(gate, normal | overrides), 0)
        self.assertNotEqual(self.gate_result(gate, docs | dict(EVENT_NAME='push')), 0)
        self.assertNotEqual(self.gate_result(gate, master | dict(CACHE_FLAKE_INFO='skipped')), 0)

    def gate_result(self, gate, env):
        return subprocess.run(['bash', '-eo', 'pipefail', '-c', gate],
                              env=os.environ | env, capture_output=True).returncode

    def test_driver_cache_and_signing_key(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nix = root / 'nix'
            nix.write_text(f'#!{shutil.which("bash")}\n' + '''case "$1" in
  eval) echo 'driverDrvs=("/drv^*"); drivers=(/driver); scenarioTests=(/test)' ;;
  path-info) [[ $* == *"/test" && $TEST_CACHED == true ]] ;;
  *) echo unexpected-nix-build >> "$CALL_LOG"; exit 1 ;;
esac
''')
            cachix = root / 'cachix'
            cachix.write_text(f'#!{shutil.which("bash")}\n' + 'echo "$1" >> "$CALL_LOG"\n')
            nix.chmod(0o755)
            cachix.chmod(0o755)
            for cached, key, expected, uploads in [
                ('true', '', 'false', []), ('false', '', 'true', []),
                ('false', 'test-key', 'true', ['watch-exec', 'push']),
            ]:
                output, log = root / 'output', root / 'calls'
                output.write_text('')
                log.write_text('')
                env = os.environ | dict(PATH=tmp + ':' + os.environ['PATH'],
                                        GITHUB_OUTPUT=str(output), CALL_LOG=str(log),
                                        TEST_CACHED=cached, CACHIX_SIGNING_KEY=key)
                env.pop('GITHUB_ACTIONS', None)
                subprocess.run(['bash', str(scripts / 'build_test_drivers.sh')],
                               env=env, check=True, capture_output=True)
                self.assertEqual(output.read_text(), f'run_scenario_tests={expected}\n')
                self.assertEqual(log.read_text().splitlines(), uploads)


unittest.main()
