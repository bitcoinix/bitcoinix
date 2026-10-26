# Shared imports for the assembled driver script.
from urllib.parse import parse_qs, urlparse
import base64
import hashlib
import hmac
import json
import os
import re
import shlex


def succeed(*cmds):
    """Returns the concatenated output of all cmds"""
    return machine.succeed(*cmds)

def succeed_json(cmd):
    return json.loads(succeed(cmd))

def assert_file_metadata(path, *, owner=None, group=None, mode=None, file_type=None):
    """Check only the requested fields, without following symlinks."""
    output = succeed(f"stat -c '%U %G %a %F' -- {shlex.quote(path)}").rstrip("\n")
    actual = dict(zip(("owner", "group", "mode", "file_type"), output.split(" ", 3)))
    expected = {"owner": owner, "group": group, "mode": mode, "file_type": file_type}
    for field, value in expected.items():
        if value is not None:
            assert actual[field] == value, f"{path}: expected {field}={value!r}, got {actual[field]!r}"

def assert_matches(cmd, regexp):
    assert_str_matches(succeed(cmd), regexp)

def assert_str_matches(str, regexp):
    if not re.search(regexp, str):
        raise Exception(f"Pattern '{regexp}' not found in '{str}'")

def assert_full_match(cmd, regexp):
    out = succeed(cmd)
    if not re.fullmatch(regexp, out):
        raise Exception(f"Pattern '{regexp}' doesn't match '{out}'")

def log_has_string(unit, str):
    return f"journalctl -b --output=cat -u {unit} --grep='{str}'"

def current_run_log_has_string(unit, str):
    """Like log_has_string, but ignores runs of the unit before its last (re)start"""
    invocation = f"$(systemctl show -p InvocationID --value {unit})"
    return f"journalctl -b --output=cat _SYSTEMD_INVOCATION_ID={invocation} --grep='{str}'"

def assert_no_failure(unit):
    """Unit should not have failed since the system is running"""
    machine.fail(log_has_string(unit, "Failed with result"))

def assert_running(unit):
    with machine.nested(f"waiting for unit: {unit}"):
        machine.wait_for_unit(unit)
    assert_no_failure(unit)

def wait_for_open_port(address, port):
    def is_port_open(_):
        status, _ = machine.execute(f"nc -z {address} {port}")
        return status == 0

    with machine.nested(f"Waiting for TCP port {address}:{port}"):
        retry(is_port_open)


def ip(name):
    if "netns-isolation" in enabled_tests:
        return test_data["netns"][name]["address"]
    return "127.0.0.1"
