# Shared imports for the assembled driver script.
from contextlib import contextmanager
from urllib.parse import parse_qs, unquote, urlparse
import base64
import hashlib
import hmac
import ipaddress
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

def btcpayserver_admin():
    """Returns curl's `-u` value for the admin that btcpayserver-admin creates"""
    # BTCPay accepts Basic auth for the Greenfield API only in an account's first
    # five minutes, unless its user turns it on. Restart that period.
    assert_full_match(
        "runuser -u btcpayserver -- psql -d btcpaydb -c "
        """'UPDATE "AspNetUsers" SET "Created" = now() WHERE "NormalizedUserName" = $$ADMIN@LOCALHOST$$'""",
        "UPDATE 1\n",
    )
    return "admin@localhost:$(cat /secrets/btcpayserver-admin-password)"

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

def wait_for_lnd_server():
    """Wait until lnd's server has started. lnd answers RPCs before that, and a
    stop or SIGTERM in between can make lnd panic. That exit would fail later
    `assert_no_failure("lnd")` checks. Start lnd first, or this waits until the
    driver's timeout.
    lnd starts its server once its chain has synced. In the test VM, that only
    happens with the blocks that the regtest fixture mines. Elsewhere, lnd never
    starts its server and can't panic this way. Ask the fixture, not
    `enabled_tests`, which changes when a run selects a subset of the tests.
    lnd counts its chain as synced only while the tip is less than two hours
    old, so in an older debug VM, this waits until the timeout after a restart."""
    if test_data.get("num_blocks"):
        machine.wait_until_succeeds("runuser -u operator -- lncli state | grep -q SERVER_ACTIVE")
    else:
        machine.wait_until_succeeds("runuser -u operator -- lncli getinfo")

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


def systemctl_show(units, props):
    """Fetch multiple systemd properties for multiple units in one call."""
    if not units:
        return {}
    unit_args = " ".join(shlex.quote(u if "." in u else f"{u}.service") for u in units)
    prop_args = " ".join(f"-p {p}" for p in props)
    out = succeed(f"systemctl show {prop_args} {unit_args}").rstrip("\n")
    blocks = out.split("\n\n")
    assert len(blocks) == len(units), (len(blocks), len(units), out)
    result = {}
    for unit, block in zip(units, blocks):
        vals = {}
        for line in block.splitlines():
            key, _, val = line.partition("=")
            vals[key] = val
        result[unit] = vals
    return result


def check_lnd_macaroon_permissions(lnd, macaroon_path, rpcs, *, macaroon_user=None):
    """Check a list of RPCs against /v1/macaroon/checkpermissions in one curl call."""
    prefix = f"runuser -u {shlex.quote(macaroon_user)} -- " if macaroon_user else ""
    mac_b64 = succeed(f"{prefix}base64 -w0 {shlex.quote(macaroon_path)}").strip()
    url = f"https://{ip('lnd')}:{lnd.get('restPort', 8080)}/v1/macaroon/checkpermissions"
    sep = "---NB-CURL-SEP---"
    bodies = "\n".join(
        json.dumps(json.dumps({
            "macaroon": mac_b64,
            "fullMethod": rpc,
            "check_default_perms_from_full_method": True,
        }))
        for rpc in rpcs
    )
    # Stream payloads and read admin.macaroon inside the lnd user's shell so neither
    # macaroon ever appears in process arguments.
    admin_macaroon = shlex.quote(f"{lnd['networkDir']}/admin.macaroon")
    bash_cmd = (
        f'hdr=$(xxd -ps -c 99999 {admin_macaroon}) && first=1 && '
        '{ while IFS= read -r body; do '
        '[[ $first ]] || printf "next\\n"; first=; '
        f'printf \'url = "{url}"\\ncacert = "/secrets/lnd-cert"\\nmax-time = 30\\n\' ; '
        'printf \'header = "Grpc-Metadata-macaroon: %s"\\n\' "$hdr"; '
        'printf \'data-binary = %s\\n\' "$body"; '
        f'printf \'write-out = "\\\\n{sep}\\\\n"\\n\'; '
        'done; } | curl -sS -K -'
    )
    out = succeed(
        f"runuser -u {shlex.quote(lnd['user'])} -- bash -c {shlex.quote(bash_cmd)} <<'EOF'\n{bodies}\nEOF"
    )
    chunks = [c.strip() for c in out.split(sep) if c.strip()]
    assert len(chunks) == len(rpcs), (len(chunks), len(rpcs), out)
    return [json.loads(c) for c in chunks]


def rtl_login(url, jar):
    """Fetch RTL's login page, authenticate with /secrets/rtl-password, and return (xsrf, token)."""
    page = succeed(f"rm -f {shlex.quote(jar)} && curl -fsS -b {shlex.quote(jar)} -c {shlex.quote(jar)} {shlex.quote(url + '/')}")
    assert "<title>RTL</title>" in page, page
    xsrf = unquote(succeed(f"awk '$6 == \"XSRF-TOKEN\" {{ print $7 }}' {shlex.quote(jar)}").strip())
    password = succeed("cat /secrets/rtl-password").rstrip("\n")
    login = json.dumps({
        "authenticateWith": "PASSWORD",
        "authenticationValue": hashlib.sha256(password.encode()).hexdigest(),
    })
    response = succeed_json(
        f"curl -fsS --max-time 60 -b {shlex.quote(jar)} -c {shlex.quote(jar)} "
        f"-H 'Content-Type: application/json' -H {shlex.quote(f'X-XSRF-TOKEN: {xsrf}')} "
        f"--data-binary {shlex.quote(login)} {shlex.quote(url + '/api/authenticate')}"
    )
    return xsrf, response["token"]
