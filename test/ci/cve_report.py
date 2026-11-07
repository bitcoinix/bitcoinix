"""`cve.py report`: keep the pinned tracking issue in sync with a scan.

Everything above the `<!-- cve-scan-report -->` line of the issue body belongs to
people. Below it the job writes the latest summary and, in an HTML comment, the
set of active CVEs of the last reported scan. The same package/CVE pairs refresh
that part without a comment (or write nothing when it would not change).
Different pairs post one comment, then rewrite it. The comment goes first: if it
fails, the next run tries again, which at worst repeats a comment; the other
order could lose the notice. Severity, score and KEV status are shown, never
compared. The tool NEVER creates, closes, reopens or labels an issue: a
maintainer pins it and stores its number in CVE_SCAN_ISSUE, so no title search
can pick up a human's issue. Needs gh on PATH and GH_TOKEN in the environment.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from cve_common import DIGITS, SET_LINE, SEVERITIES, Failure, read_text, utcnow, warn, write_text

REPORT_MARKER = "<!-- cve-scan-report -->"
SET_BEGIN = "<!-- cve-scan-set"
SET_END = "-->"
MAX_TEXT = 60000  # GitHub rejects bodies and comments over 65536 characters
GH_TIMEOUT = 300
POINTER = "The summary is too large for this issue. It is in the `vulnix-report` artifact of the run."
SCORE_TEXT = re.compile(r"[0-9]+(\.[0-9]+)?")
SERVER_URL = re.compile(r"https?://[A-Za-z0-9.:\[\]-]+")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


class GhCli:
    """The gh command line. GH_TOKEN reaches it by inheritance and nowhere else."""

    def view_body(self, issue):
        output = self.gh("view", issue, "--json", "body", capture=True)
        try:
            document = json.loads(output.decode("utf-8"))
        except (ValueError, RecursionError):
            raise Failure("gh issue view printed no JSON") from None
        if not isinstance(document, dict) or "body" not in document:
            raise Failure("gh issue view printed no issue body")
        body = "" if document["body"] is None else document["body"]
        # JSON can carry a lone surrogate, which no body file could hold.
        if not isinstance(body, str) or body != body.encode("utf-8", "replace").decode():
            raise Failure("gh issue view printed no valid issue body")
        return body

    def comment(self, issue, text):
        self.write("comment", issue, text)

    def edit(self, issue, text):
        self.write("edit", issue, text)

    def write(self, verb, issue, text):
        # Bodies go through a file, never through the command line.
        with tempfile.TemporaryDirectory(prefix="cve-report-") as directory:
            path = Path(directory) / "body.md"
            write_text(path, text)
            self.gh(verb, issue, "--body-file", str(path))

    def gh(self, verb, issue, *arguments, capture=False):
        """Only the view's output is read; a write prints what gh prints, its URL."""
        command = ["gh", "issue", verb, issue, *arguments]
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE if capture else None,
                                    timeout=GH_TIMEOUT)
        except subprocess.TimeoutExpired:
            raise Failure(f"gh issue {verb} timed out after {GH_TIMEOUT} s") from None
        except OSError as error:
            raise Failure(f"cannot run gh: {error.strerror}") from None
        if result.returncode != 0:
            raise Failure(f"gh issue {verb} failed with exit {result.returncode}")
        return result.stdout


def split_body(text):
    """The lines before the first marker line, and the report lines after it.
    Without a marker all is human: an old set left there is never reused."""
    lines = text.split("\n")[:-1]
    end = lines.index(REPORT_MARKER) if REPORT_MARKER in lines else len(lines)
    human = "".join(line + "\n" for line in lines[:end])
    return human, [line for line in lines[end + 1:] if line != REPORT_MARKER]


def stored_set(report_lines):
    """The lines of the first set block, to its end or to the end of the body."""
    if SET_BEGIN not in report_lines:
        return []
    start = report_lines.index(SET_BEGIN) + 1
    rest = report_lines[start:]
    return rest[:rest.index(SET_END)] if SET_END in rest else rest


def parse_set(lines, *, strict):
    """Sorted unique set lines. An invalid line is an error in the scan's set and
    dropped from the stored one, where it could end the HTML comment or a mention."""
    valid = set()
    for line in lines:
        if not line:
            continue
        if SET_LINE.fullmatch(line):
            valid.add(line)
        elif strict:
            raise Failure(f'set line is not "<package> <version> <CVE>": {line!r:.200}')
        else:
            warn(f'dropping stored set line that is not "<package> <version> <CVE>": {line!r:.200}')
    return sorted(valid)


def identity(line):
    """Package and CVE: a new package version of an unfixed CVE is no change."""
    package, _, cve = line.split(" ")
    return f"{package} {cve}"


def run_link():
    names = ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID")
    server, repository, run_id = (os.environ.get(name, "") for name in names)
    if not (server and repository and run_id):
        return None
    if not (SERVER_URL.fullmatch(server) and REPOSITORY.fullmatch(repository)
            and DIGITS.fullmatch(run_id)):
        raise Failure("unexpected GITHUB_* value")
    return f"Run: {server}/{repository}/actions/runs/{run_id}"


def build_body(human, summary, new_lines, link):
    """Human part, marker, summary and set. An oversized summary becomes a pointer;
    the set is never cut, or the next run would report false "resolved" entries."""
    block = SET_BEGIN + "\n" + "".join(line + "\n" for line in new_lines) + SET_END + "\n"
    body = human + REPORT_MARKER + "\n\n" + summary + "\n" + block
    if len(body) <= MAX_TEXT:
        return body
    warn("summary too large for the issue body, replacing it with a pointer to the artifact")
    pointer = POINTER + "\n" + (link + "\n" if link else "")
    body = human + REPORT_MARKER + "\n\n" + pointer + "\n" + block
    if len(body) > MAX_TEXT:
        raise Failure(f"the CVE set alone exceeds {MAX_TEXT} characters, not writing a truncated set")
    return body


def read_details(path):
    """CVE -> the valid fields of its details line; the last line of a CVE wins."""
    details = {}
    for line in read_text(path).split("\n"):
        fields = line.split("\t")
        known = details.setdefault(fields[0], {})
        if len(fields) > 1 and fields[1] in SEVERITIES:
            known["severity"] = fields[1]
        if len(fields) > 2 and SCORE_TEXT.fullmatch(fields[2]):
            known["score"] = fields[2]
        if len(fields) > 3 and fields[3] in ("yes", "no"):
            known["kev"] = fields[3]
    return details


def describe(ids, set_lines, details):
    """One item per identity: its versions and, for new findings, its details."""
    versions = {}
    for line in set_lines:
        package, version, cve = line.split(" ")
        seen = versions.setdefault(f"{package} {cve}", [])
        if (version or "unknown") not in seen:
            seen.append(version or "unknown")
    items = []
    for key in ids:
        package, cve = key.split(" ")
        item = f"{package} {', '.join(versions.get(key, ['unknown']))} {cve}"
        if details is not None:
            known = details.get(cve, {})
            item += (f" — severity: {known.get('severity', 'unknown')}, CVSS "
                     f"{known.get('score', 'unknown')}, known exploited: {known.get('kev', 'unknown')}")
        items.append(item)
    return items


def build_comment(new_items, resolved_items, active, link, now, lists=True):
    """New, resolved, the run; counts alone when the lists do not fit."""
    lines = [f"### CVE set changed on {now:%Y-%m-%d}", "",
             f"New: {len(new_items)}, resolved: {len(resolved_items)}, active: {active}."]
    if active == 0:
        lines += ["", "The scan is clean."]
    if not lists:
        lines += ["", "The lists are too long for a comment. The issue body has the full set."]
    for heading, items in (("New", new_items), ("Resolved", resolved_items)):
        if lists and items:
            lines += ["", f"#### {heading}", "", *(f"- {item}" for item in items)]
    text = "\n".join([*lines, ""]) + "\n" + (link + "\n" if link else "")
    if len(text) > MAX_TEXT and lists:
        return build_comment(new_items, resolved_items, active, link, now, lists=False)
    return text


def check_arguments(issue, summary_path, set_path, details_path):
    if not DIGITS.fullmatch(issue):
        raise Failure(f"issue number must be digits, got {issue!r:.100}")
    for label, path in (("summary", summary_path), ("set", set_path), ("details", details_path)):
        if not Path(path).is_file():
            raise Failure(f"{label} file not found: {path}")


def report(issue, summary_path, set_path, details_path, github):
    # Every local input is read and checked before the first gh call.
    check_arguments(issue, summary_path, set_path, details_path)
    summary = read_text(summary_path)
    new = parse_set(read_text(set_path).split("\n"), strict=True)
    details = read_details(details_path)
    link, now = run_link(), utcnow()
    # gh used to print the body with --jq and a trailing newline; the web
    # editor saves CRLF.
    text = (github.view_body(issue) + "\n").replace("\r", "")
    human, report_lines = split_body(text)
    old = parse_set(stored_set(report_lines), strict=False)
    old_ids, new_ids = {identity(line) for line in old}, {identity(line) for line in new}
    added, resolved = sorted(new_ids - old_ids), sorted(old_ids - new_ids)
    body = build_body(human, summary, new, link)
    if not added and not resolved:
        return refresh(issue, text, body, github)
    comment = build_comment(describe(added, new, details), describe(resolved, old, None),
                            len(new_ids), link, now)
    github.comment(issue, comment)
    github.edit(issue, body)
    print(f"updated issue #{issue}: {len(added)} new, {len(resolved)} resolved")
    return 0


def refresh(issue, text, body, github):
    """Same pairs: rewrite a changed body (versions, scan date, first clean scan) so
    a stale one cannot pass for current. Trailing newlines are no change."""
    if text.rstrip("\n") == body.rstrip("\n"):
        print(f"no change in the CVE set, not touching issue #{issue}")
        return 0
    github.edit(issue, body)
    print(f"refreshed the report in issue #{issue} (CVE set unchanged)")
    return 0
