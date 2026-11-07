"""Scan the bitcoinix service closure for known CVEs and track them in an issue.

  cve.py scan
  cve.py report <issue-number> <summary.md> <cve-set.txt> <cve-details.tsv>

cve_scan.py has the scan, cve_report.py the tracking issue, cve_common.py what
both share.
"""

from pathlib import Path
import sys

# -I keeps the working directory and PYTHON* variables out of sys.path; the
# modules next to this file are part of the tool.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from cve_common import Failure, log, warn  # noqa: E402
import cve_report  # noqa: E402
import cve_scan  # noqa: E402

USAGE = ("usage: cve.py scan | "
         "cve.py report <issue-number> <summary.md> <cve-set.txt> <cve-details.tsv>")


def main(argv=None):
    # The report arguments are data (the issue number comes from a repository
    # variable), so they are never parsed as options.
    argv = sys.argv[1:] if argv is None else list(argv)
    if argv in (["-h"], ["--help"]):
        print(__doc__, end="")
        return 0
    try:
        if argv == ["scan"]:
            return cve_scan.scan(Path(__file__).resolve().parents[2])
        if argv[:1] == ["report"] and len(argv) == 5:
            return cve_report.report(*argv[1:], cve_report.GhCli())
        raise Failure(USAGE)
    except Failure as failure:
        (log if argv == ["scan"] else warn)(str(failure))
        return 1


if __name__ == "__main__":
    sys.exit(main())
