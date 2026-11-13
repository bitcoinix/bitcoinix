"""Check the jq filters of lnd-create-macaroons against adversarial lncli output."""

import json
from pathlib import Path
import subprocess
import sys
import unittest


filters = Path(sys.argv.pop(1))
FIRST, LAST = str(0x6E62 << 48), str((0x6E63 << 48) - 1)
CURRENT = str(int(FIRST) + 1)


def jq(args, output):
    return subprocess.run(["jq", *args], input=output, capture_output=True, text=True)


def stale_ids(output):
    result = jq([
        "-nr", "-f", filters / "stale-ids.jq", "--arg", "first", FIRST, "--arg", "last", LAST,
        "--argjson", "current", json.dumps([CURRENT]),
    ], output)
    return result.returncode, result.stdout.split()


def listing(*ids):
    return json.dumps({"root_key_ids": list(ids)})


class StaleIdsTests(unittest.TestCase):
    def assert_stale(self, output, expected):
        self.assertEqual(stale_ids(output), (0, expected))

    def test_valid_listings(self):
        self.assert_stale(listing(), [])
        self.assert_stale(listing("0"), [])
        # lncli indents its output
        self.assert_stale(json.dumps({"root_key_ids": ["0", FIRST]}, indent=4), [FIRST])

    def test_prints_unused_ids_in_the_range(self):
        below, above = str(int(FIRST) - 1), str(int(LAST) + 1)
        self.assert_stale(
            listing("0", "1", below, FIRST, CURRENT, LAST, above, "18446744073709551615"),
            [FIRST, LAST],
        )

    def test_rejects_unexpected_output_without_printing_ids(self):
        # Every rejected listing contains a stale ID, which must not be printed
        for output in [
            "", "null", "[]", "{}", f'{{"ids":["{FIRST}"]}}',
            f'{{"root_key_ids":"{FIRST}"}}', '{"root_key_ids":null}',
            f'{{"root_key_ids":{{"{FIRST}":true}}}}',
            listing(FIRST) + listing(FIRST),
            listing(FIRST, FIRST),
            f'{{"root_key_ids":[{FIRST}]}}', f'{{"root_key_ids":["{FIRST}",1]}}',
            listing(FIRST, "07953919891889717248"), listing(FIRST, "00"), listing(FIRST, ""),
            listing(FIRST, "-1"), listing(FIRST, "+1"), listing(FIRST, " 1"), listing(FIRST, "1e3"),
            listing(FIRST, "0x6e62000000000000"),
            listing(FIRST, "18446744073709551616"), listing(FIRST, "100000000000000000000"),
            # ^ and $ would match around these newlines
            listing("795400000000000000\n"), listing(FIRST + "\n"), listing("\n" + FIRST),
            listing(FIRST, CURRENT)[:-3],
        ]:
            with self.subTest(output=output):
                status, printed = stale_ids(output)
                self.assertNotEqual(status, 0)
                self.assertEqual(printed, [])


class DeletedTests(unittest.TestCase):
    def deleted(self, output):
        return jq(["-se", "-f", filters / "deleted.jq"], output).returncode

    def test_valid_outputs(self):
        for output in ['{"deleted": true}', '{\n    "deleted":  false\n}\n']:
            with self.subTest(output=output):
                self.assertEqual(self.deleted(output), 0)

    def test_rejects_unexpected_output(self):
        for output in [
            "", "null", "true", "[]", "{}", '{"deleted":null}', '{"deleted":"true"}',
            '{"deleted":1}', '[{"deleted":true}]', '{"deleted":true}{"deleted":true}',
            '{"deleted":tr',
        ]:
            with self.subTest(output=output):
                self.assertNotEqual(self.deleted(output), 0)


unittest.main()
