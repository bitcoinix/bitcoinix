"""Shared pieces of the CVE tools: handled errors, bounded input, the token grammar."""

from datetime import datetime, timezone
import os
import re
import sys

MAX_INPUT_BYTES = 64 * 1024 * 1024  # any file the tools read

# Everything that reaches a comment or the managed part of the body is a fixed
# string or one of these tokens. The store name alphabet has no space, newline,
# backtick, `|`, `<`, `@`, `[`, `*` or `#`, so vulnix data cannot break the set
# line grammar, end the HTML comment, mention anyone or add markup.
STORE_NAME_CHAR = r"[A-Za-z0-9+._?=-]"
PACKAGE = re.compile(rf"{STORE_NAME_CHAR}{{1,211}}")
VERSION = re.compile(rf"{STORE_NAME_CHAR}{{0,211}}")
CVE = r"CVE-[0-9]{4}-[0-9]{1,23}"  # 32 characters at most
CVE_ID = re.compile(CVE)
SET_LINE = re.compile(rf"({STORE_NAME_CHAR}{{1,211}}) ({STORE_NAME_CHAR}{{0,211}}) ({CVE})")
SEVERITIES = ("Critical", "High", "Medium", "Low", "None")
DIGITS = re.compile(r"[0-9]+")


class Failure(Exception):
    """A handled error: main prints the message and exits 1."""


def utcnow():
    """The current time, or SOURCE_DATE_EPOCH (the reproducible-builds convention)."""
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    try:
        return datetime.fromtimestamp(int(epoch), timezone.utc) if epoch else datetime.now(timezone.utc)
    except (ValueError, OverflowError, OSError):
        raise Failure("SOURCE_DATE_EPOCH must be a number of seconds") from None


def read_text(path):
    """A file's text, line ends untouched; Failure when too large or not UTF-8."""
    with open(path, "rb") as file:
        data = file.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise Failure(f"{path} is larger than {MAX_INPUT_BYTES} bytes")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise Failure(f"{path} is not valid UTF-8") from None


def write_text(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as file:
        file.write(text)


def log(message, end="\n"):
    # Flushed, so the lines stay in order with the output of nix and vulnix.
    print(message, end=end, flush=True)


def warn(message):
    print(f"cve-report: {message}", file=sys.stderr, flush=True)
