"""`cve.py scan`: build a representative node and run vulnix on its runtime closure.

bitcoinix ships NixOS modules, not a flat package set, so the honest scan target
is a built node's RUNTIME closure. test/ci/scan-node.nix enables the shipped
services and vulnix checks the system toplevel, the software a user runs; a
test-derivation closure would add compilers whose CVEs never reach a node.
Outputs in the repository root: vulnix-report.json, cve-summary.md, cve-set.txt
(sorted "<pname> <version> <CVE>" lines of the active CVEs, empty when clean) and
cve-details.tsv ("<CVE>\\t<severity>\\t<CVSS>\\t<known exploited>"). Exit 0 on a
completed scan, findings are data; exit 1 on a FAILED scan, so a broken scan
fails the job instead of passing for clean and resolving every tracked CVE.
"""

from dataclasses import dataclass
import json
import os
import subprocess
import time

from cve_common import CVE_ID, PACKAGE, VERSION, Failure, log, read_text, utcnow, write_text

ATTEMPTS = 5
RETRY_SECONDS = 60  # the tests set this to 0
# CISA's mirror of the KEV catalog, minutes behind cisa.gov, keeps the scan on
# GitHub, where the job already fetches its sources. It has no `main` branch.
KEV_MIRROR = ("https://raw.githubusercontent.com/cisagov/kev-data/refs/heads/develop/"
              "known_exploited_vulnerabilities.csv")
NIX = ["nix", "--extra-experimental-features", "nix-command flakes"]
SCAN_TARGET = ("representative node toplevel (secure-node preset: tor, operator, nodeinfo; "
               "bitcoind + clightning/clnrest + lnd + charge-lnd + electrs + fulcrum + "
               "btcpayserver/nbxplorer + mempool + rtl + unbeholden-wallet + backups), runtime closure")
TRIAGE = [
    "Triage: fix the package upstream in nixpkgs and move the pin (`helper/update-flake.sh`),",
    "or override it in `pkgs/` until nixpkgs catches up; whitelist only vulnix pname collisions",
    "or CVEs that are N/A to this runtime closure in `.github/cve-whitelist.toml`",
    "(this scans the node's RUNTIME closure, so build tooling should not appear;"
    " if it does, find out why).",
]
SCAN_OUTPUTS = ("vulnix-report.json", "cve-summary.md", "cve-set.txt", "cve-details.tsv")
TOKENS = ("GH_TOKEN", "GITHUB_TOKEN")
NOT_REPORTING = " — not reporting a result"


def severity(score):
    """The CVSS v3 rating of a base score. vulnix leaves out CVEs without a v3 score
    and scores of 0.0; those read "unknown", so "None" only applies if it reports 0.0."""
    if score is None:
        return "unknown"
    if score >= 9:
        return "Critical"
    if score >= 7:
        return "High"
    if score >= 4:
        return "Medium"
    return "Low" if score > 0 else "None"


@dataclass(frozen=True)
class Finding:
    """A store path with active CVEs, as one vulnix report entry lists it."""
    package: str
    version: str
    cves: tuple            # active CVEs in `affected_by` order, repeats kept
    scores: dict           # score per active CVE that has one
    exploited: frozenset

    def max_score(self):
        """The highest score of an active CVE, 0 without one."""
        return max(self.scores.values(), default=0)

    def details(self, cve):
        score = self.scores.get(cve)
        text = "unknown" if score is None else str(score)
        return severity(score), text, "yes" if cve in self.exploited else "no"


def check_shape(entry):
    """vulnix always writes these fields; anything else is not a finding list."""
    shape = f"vulnix report entries have an unexpected shape{NOT_REPORTING}"
    if not (isinstance(entry, dict) and isinstance(entry.get("affected_by"), list)
            and isinstance(entry.get("whitelisted"), list)):
        raise Failure(shape)
    package = entry.get("pname")
    package = entry.get("name") if package is None else package
    if not isinstance(package, str):
        raise Failure(shape)
    return package


def check_tokens(package, version, cves):
    version = "" if version is None else version
    if not PACKAGE.fullmatch(package) or not isinstance(version, str) or not VERSION.fullmatch(version):
        value = package if not PACKAGE.fullmatch(package) else version
        raise Failure(f"vulnix report has an unexpected package name or version: "
                      f"{value!r:.100}{NOT_REPORTING}")
    for cve in cves:
        if not isinstance(cve, str) or not CVE_ID.fullmatch(cve):
            raise Failure(f"vulnix report has an unexpected CVE id: {cve!r:.100}{NOT_REPORTING}")
    return version


def active_scores(scores, cves):
    """The scores of the active CVEs. Whitelisted CVEs are scored too and ignored."""
    if scores is None:
        return {}
    if not isinstance(scores, dict):
        raise Failure(f"vulnix report has an unexpected CVSS score: {scores!r:.100}{NOT_REPORTING}")
    active = {}
    for cve in cves:
        score = scores.get(cve)
        if score is None:
            continue
        if isinstance(score, bool) or not isinstance(score, (int, float)) or not 0 <= score <= 10:
            raise Failure(f"vulnix report has an unexpected CVSS score: {cve} {score!r:.100}"
                          f"{NOT_REPORTING}")
        active[cve] = score
    return active


def finding_from_entry(entry):
    """The entry's finding, None without active CVEs; Failure on unexpected data.
    vulnix moves whitelisted CVEs to `whitelisted`, so `affected_by` alone decides:
    an entry with a scoped whitelisted CVE and a new one is still reported."""
    package = check_shape(entry)
    cves = tuple(entry["affected_by"])
    version = check_tokens(package, entry.get("version"), cves)
    scores = active_scores(entry.get("cvssv3_basescore"), cves)
    exploited = entry.get("known_exploited")
    exploited = [] if exploited is None else exploited
    if not isinstance(exploited, list) or not all(isinstance(cve, str) for cve in exploited):
        raise Failure(f"vulnix report has an unexpected known_exploited value{NOT_REPORTING}")
    return Finding(package, version, cves, scores, frozenset(exploited)) if cves else None


def reject_constant(name):
    raise ValueError(f"{name} is not a JSON number")


def load_findings(path, rc):
    """The findings of a vulnix report. rc 2 is also click's usage error, so the
    output must be a JSON array, or an error would read as a clean scan."""
    invalid = f"vulnix produced no valid JSON (rc={rc}){NOT_REPORTING}"
    try:
        document = json.loads(read_text(path), parse_constant=reject_constant)
    except (Failure, ValueError, RecursionError):
        raise Failure(invalid) from None
    if not isinstance(document, list):
        raise Failure(invalid)
    findings = [finding_from_entry(entry) for entry in document]
    return [finding for finding in findings if finding is not None]


def render_summary(findings, now):
    lines = [f"# CVE scan — {now:%Y-%m-%dT%H:%MZ}", "", f"Scanned: {SCAN_TARGET}",
             f"Affected store paths with non-whitelisted CVEs: **{len(findings)}**", ""]
    if not findings:
        return "\n".join([*lines, "No action needed."]) + "\n"
    for finding in sorted(findings, key=lambda finding: -finding.max_score()):
        lines.append(f"## {finding.package} {finding.version} — CVSS {finding.max_score()}")
        for cve in finding.cves:
            rating, text, exploited = finding.details(cve)
            lines.append(f"- {cve} — severity: {rating}, CVSS {text}, known exploited: {exploited}")
    return "\n".join([*lines, "", *TRIAGE]) + "\n"


def render_set(findings):
    lines = {f"{finding.package} {finding.version} {cve}" for finding in findings
             for cve in finding.cves}
    return "".join(line + "\n" for line in sorted(lines))


def render_details(findings):
    """One line per active CVE, from its first finding. Kept out of the set, so
    that a rescored CVE is not a change."""
    first = {}
    for finding in findings:
        for cve in finding.cves:
            first.setdefault(cve, finding.details(cve))
    return "".join("\t".join((cve, *first[cve])) + "\n" for cve in sorted(first))


def scan_env():
    """The environment of nix and vulnix, which never need a GitHub token."""
    return {key: value for key, value in os.environ.items() if key not in TOKENS}


def build_toplevel(repo):
    """Build the node's system toplevel; None, after writing the empty results, on failure."""
    log("::group::build node toplevel")
    command = [*NIX, "build", "--no-link", "--print-out-paths", "--impure", "-f",
               "test/ci/scan-node.nix"]
    result = subprocess.run(command, cwd=repo, env=scan_env(), stdout=subprocess.PIPE)
    if result.returncode != 0:
        log("node toplevel build failed")
        write_text(repo / "vulnix-report.json", "[]\n")
        write_text(repo / "cve-summary.md", "")
        return None
    toplevel = result.stdout.decode("utf-8", "replace").rstrip("\n")
    log(toplevel)
    log("::endgroup::")
    return toplevel


def run_vulnix(repo, toplevel):
    """vulnix's exit code: 0 clean, 2 findings, 1 scan error. NVD serves its feeds
    slowly and sometimes stops mid-feed; a feed that fails vulnix's own retries
    ends the run with rc=1, so it is retried here. --closure scans the runtime
    closure, not the deriver's build closure; --kev reads the KEV catalog."""
    log("::group::vulnix")
    command = [*NIX, "shell", "--impure", "-f", "test/ci/vulnix.nix", "-c", "vulnix", "--closure",
               "--json", "--kev", "--kev-mirror", KEV_MIRROR,
               "--whitelist", str(repo / ".github/cve-whitelist.toml"), toplevel]
    errors = repo / "vulnix.err"
    for attempt in range(1, ATTEMPTS + 1):
        with open(repo / "vulnix-report.json", "wb") as out, open(errors, "wb") as err:
            rc = subprocess.run(command, cwd=repo, env=scan_env(), stdout=out, stderr=err).returncode
        stderr = errors.read_bytes().decode("utf-8", "replace")
        if rc != 1:
            break
        last = stderr.removesuffix("\n").rsplit("\n", 1)[-1]
        log(f"vulnix attempt {attempt} failed (rc=1): {last}")
        if attempt < ATTEMPTS:
            time.sleep(RETRY_SECONDS)
    log(stderr, end="")
    log(f"vulnix exit={rc}")
    log("::endgroup::")
    return rc


def scan(repo):
    # A failed run must not leave an earlier run's results for the next step.
    for name in SCAN_OUTPUTS:
        (repo / name).unlink(missing_ok=True)
    toplevel = build_toplevel(repo)
    if toplevel is None:
        return 1
    rc = run_vulnix(repo, toplevel)
    if rc not in (0, 2):
        log(f"vulnix scan FAILED (rc={rc}){NOT_REPORTING}")
        return 1
    findings = load_findings(repo / "vulnix-report.json", rc)
    summary, found, details = (render_summary(findings, utcnow()), render_set(findings),
                               render_details(findings))
    write_text(repo / "cve-summary.md", summary)
    write_text(repo / "cve-set.txt", found)
    write_text(repo / "cve-details.tsv", details)
    log(f"scan complete: found={'true' if findings else 'false'}")
    return 0
