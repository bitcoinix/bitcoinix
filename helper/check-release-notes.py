"""Check release notes against the PR base, or against release preparation before tagging."""

from collections import Counter
from html.parser import HTMLParser
import os
from pathlib import Path
import posixpath
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"
NOTE = re.compile(rf"(?P<guide>docs/(?:release-notes|upgrading))/(?P<version>{VERSION})(?P<draft>/[^/]+)?\.md")
NOTICE = re.compile(rf"modules/versioning/({VERSION})/[^/]+\.nix")
DRAFT_LINK = re.compile(rf"(?:^|/)(?:upgrading|release-notes)/{VERSION}/[^/]+\.(?:md|html)$")
INDEXES = ("docs/SUMMARY.md", "docs/upgrading.md", "docs/release-notes.md")


def version(value):
    if not re.fullmatch(VERSION, value):
        sys.exit(f"Invalid release version: {value!r}")
    return tuple(map(int, value.split(".")))


def git(*args):
    return subprocess.check_output(["git", *args])


def paths(revision, *directories):
    if revision:
        data = git("ls-tree", "-rz", "--name-only", revision, "--", *directories)
    else:
        data = git("ls-files", "-z", "--", *directories)
    return {os.fsdecode(path) for path in data.split(b"\0") if path}


def version_at(revision):
    if "version.nix" in paths(revision, "version.nix"):
        expr = git("show", f"{revision}:version.nix").decode()
        return version(subprocess.check_output(["nix", "eval", "--raw", "--expr", expr], text=True))
    return ()  # Sort before every version if the repository predates version.nix.


class Markdown(HTMLParser):
    """Use CommonMark link destinations and visible headings, including inline formatting."""

    def __init__(self, source):
        super().__init__()
        self.links = []
        self.headings = []
        self.title = None
        self.feed(subprocess.check_output(["cmark", "--unsafe"], input=source).decode())
        self.close()

    def handle_starttag(self, tag, attrs):
        if tag == "h4":
            self.title = []
        elif tag == "a":
            href = dict(attrs).get("href")
            if href:
                self.links.append(href)

    def handle_data(self, data):
        if self.title is not None:
            self.title.append(data)

    def handle_endtag(self, tag):
        if tag == "h4" and self.title is not None:
            self.headings.append("".join(self.title))
            self.title = None


def links_to_draft(link):
    url = urlsplit(link)
    path = posixpath.normpath(unquote(url.path))
    if url.netloc and url.hostname != "docs.bitcoinix.net":
        if (url.hostname not in ("github.com", "raw.githubusercontent.com")
                or not path.startswith("/bitcoinix/bitcoinix/")):
            return False
    return DRAFT_LINK.search(path) is not None


def check_tree(documents, finalized):
    for index in INDEXES:
        if index in documents:
            for link in Markdown(Path(index).read_bytes()).links:
                if links_to_draft(link):
                    yield f"{index}: link to the version page instead of the individual draft {link}."

    for path in sorted(documents):
        note = NOTE.fullmatch(path)
        if not note or version(note["version"]) > finalized:
            continue
        if note["draft"]:
            yield (f"Draft {path} belongs to finalized version {note['version']}. "
                   "Consolidate it or move it and its Nix notice to the next open milestone.")
        elif re.search(rb"^TBD\.", Path(path).read_bytes(), re.MULTILINE):
            yield f"Replace the TBD contents of {path} before finalizing version {note['version']}."


def check_new_notices(base, finalized):
    # A pure rename inside the same version preserves an existing notice.
    changes = git("diff", "--name-status", "-z", "--find-renames=100%", "--diff-filter=AR",
                  base, "--", "modules/versioning")
    fields = iter(os.fsdecode(changes).split("\0")[:-1])
    for status in fields:
        path = next(fields)
        old = None
        if status.startswith("R"):
            old, path = NOTICE.fullmatch(path), next(fields)
        notice = NOTICE.fullmatch(path)
        if notice and version(notice[1]) <= finalized and (not old or old[1] != notice[1]):
            yield (f"New migration notice {path} belongs to an already finalized version. "
                   "Move it and its drafts to the next open milestone.")


def check_consolidation(documents, base, previous, finalized):
    # Consume one heading per draft so two identically titled entries both survive.
    remaining = {}
    for path in sorted(paths(base, "docs/upgrading", "docs/release-notes")):
        note = NOTE.fullmatch(path)
        if not note or not note["draft"] or not previous < version(note["version"]) <= finalized:
            continue
        page = f"{note['guide']}/{note['version']}.md"
        if page not in remaining:
            remaining[page] = Counter(Markdown(Path(page).read_bytes()).headings if page in documents else [])
        headings = Markdown(git("show", f"{base}:{path}")).headings
        if not headings:
            yield f"{path} at {base} has no fourth-level heading to match in {page}."
        for heading in headings:
            if remaining[page][heading]:
                remaining[page][heading] -= 1
            else:
                yield f'{page} is missing the heading "{heading}" from {path}.'


def release_preparation(finalized):
    # Follow master across merge commits. A later edit or a comment-only change to
    # version.nix must not hide the drafts that existed when the version advanced.
    commits = git("log", "--first-parent", "--format=%H", "HEAD", "--", "version.nix")
    for commit in commits.decode().splitlines():
        parents = git("rev-list", "--parents", "-n1", commit).decode().split()[1:]
        if not parents:
            if git("rev-parse", "--is-shallow-repository").strip() == b"true":
                sys.exit("Missing release-preparation history. Run git fetch --unshallow and retry.")
            return commit, None, ()
        previous = version_at(parents[0])
        if previous != finalized:
            return commit, parents[0], previous
    sys.exit("Could not find the release-preparation commit for version.nix.")


def check(finalized, base):
    documents = paths(None, "docs")
    yield from check_tree(documents, finalized)
    # GitHub sends an all-zero "before" SHA on the first push of a branch.
    if base and not re.fullmatch("0+", base):
        previous = version_at(base)
    else:
        prepared, base, previous = release_preparation(finalized)
        # Catch notices added between finalization and signing the tag.
        yield from check_new_notices(prepared, finalized)
    if base:
        yield from check_new_notices(base, previous)
        if previous < finalized:
            yield from check_consolidation(documents, base, previous, finalized)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit("Usage: check-release-notes.sh <finalized-version> [base-commit]")
    os.chdir(Path(__file__).resolve().parent.parent)
    errors = list(check(version(sys.argv[1]), sys.argv[2] if len(sys.argv) == 3 else None))
    for error in errors:
        print(f"Error: {error}", file=sys.stderr)
    sys.exit(bool(errors))
