"""Check release notes against the PR base, or against release preparation before tagging."""

from collections import Counter
from dataclasses import dataclass, field
from functools import cache
from html.parser import HTMLParser
import os
from pathlib import Path
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit


VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"
NOTE = re.compile(rf"docs/(?P<guide>release-notes|upgrading)/(?P<version>{VERSION})(?P<draft>/[^/]+)?\.md")
NOTICE = re.compile(rf"modules/versioning/({VERSION})/[^/]+\.nix")
DRAFT_LINK = re.compile(rf"(?:^|/)(?:upgrading|release-notes)/{VERSION}/[^/]+\.(?:md|html)$")
INDEXES = ("docs/SUMMARY.md", "docs/upgrading.md", "docs/release-notes.md")
GUIDES = {"release-notes": "Release notes", "upgrading": "Upgrading to config version"}
CONFIG_VERSION = re.compile(r'\bnix-bitcoin\.configVersion\s*=\s*"([^"]+)"\s*;')


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


@dataclass
class Block:
    tag: str
    text: str = ""
    links: list = field(default_factory=list)


class Document(HTMLParser):
    """Read visible block text and link destinations, including inline formatting."""

    def __init__(self, html, *, book=False):
        super().__init__()
        self.links = []
        self.ids = set()
        self.blocks = []
        self.open_blocks = []
        self.read_blocks = not book
        self.in_chapter = not book
        self.feed(html)
        self.close()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "a" and "name" in attrs:
            self.ids.add(attrs["name"])
        if tag == "main":
            self.in_chapter = True
        if self.in_chapter:
            if self.read_blocks and tag in ("h1", "h2", "h3", "h4", "h5", "h6", "li", "p", "pre"):
                self.open_blocks.append(Block(tag))
            link = attrs.get({"a": "href", "img": "src"}.get(tag))
            if link:
                self.links.append(link)
                for block in self.open_blocks:
                    block.links.append(link)

    def handle_data(self, data):
        for block in self.open_blocks:
            block.text += data

    def handle_endtag(self, tag):
        if self.open_blocks and self.open_blocks[-1].tag == tag:
            self.blocks.append(self.open_blocks.pop())
        if tag == "main":
            self.in_chapter = False

    def entries(self, *, skip_footer=False):
        entries = []
        blocks = self.blocks[:-1] if skip_footer else self.blocks
        for block in blocks:
            if block.tag == "h4":
                entries.append((block.text, False))
            elif entries and block.tag in ("p", "pre", "li") and (block.text.strip() or block.links):
                entries[-1] = (entries[-1][0], True)
        return entries

    def has_tbd(self):
        return any(block.tag == "p" and block.text.startswith("TBD.") for block in self.blocks)

    def ends_with_config_version(self, number):
        if not self.blocks or self.blocks[-1].tag not in ("p", "pre"):
            return False
        return CONFIG_VERSION.findall(self.blocks[-1].text)[-1:] == [number]


@cache
def markdown(source):
    return Document(subprocess.check_output(["cmark", "--unsafe"], input=source).decode())


def links_to_draft(link):
    url = urlsplit(link)
    path = posixpath.normpath(unquote(url.path))
    if url.netloc and url.hostname != "docs.bitcoinix.net":
        if (url.hostname not in ("github.com", "raw.githubusercontent.com")
                or not path.startswith("/bitcoinix/bitcoinix/")):
            return False
    return DRAFT_LINK.search(path) is not None


def local_chapter(link, page):
    url = urlsplit(link)
    if url.scheme or url.netloc:
        return None
    return posixpath.normpath(posixpath.join(posixpath.dirname(page), unquote(url.path)))


def check_navigation(index, page, upcoming):
    doc = markdown(Path(index).read_bytes())
    entries = [block for block in doc.blocks if block.tag == "li"
               and any(local_chapter(link, index) == page for link in block.links)]
    if not entries:
        yield f"{index}: add a link to {page}."
    elif index != "docs/SUMMARY.md":
        for entry in entries:
            if ("(upcoming)" in entry.text) != upcoming:
                action = "add" if upcoming else "remove"
                yield f"{index}: {action} the (upcoming) label for {page}."


def check_page(page, guide, number, upcoming):
    doc = markdown(Path(page).read_bytes())
    title = f"{GUIDES[guide]} {number}"
    if not doc.blocks or (doc.blocks[0].tag, doc.blocks[0].text) != ("h1", title):
        yield f"{page}: start the page with '# {title}'."
    if upcoming:
        if len(doc.blocks) < 2 or doc.blocks[1].tag != "p" or not doc.blocks[1].text.startswith("TBD."):
            yield f"{page}: keep the TBD page until version {number} is finalized."
    else:
        if doc.has_tbd():
            yield f"Replace the TBD contents of {page} before finalizing version {number}."
        for link in doc.links:
            if links_to_draft(link):
                yield f"{page}: replace the link to the individual draft {link}."
        if guide == "upgrading":
            assignment = f'nix-bitcoin.configVersion = "{number}";'
            if not doc.ends_with_config_version(number):
                yield f"{page}: end with an instruction to set `{assignment}` after migrating."
            stale = re.compile(r'\bkeep\s+(?:nix-bitcoin\.)?configVersion\s*(?:=\s*"|at the latest finalized release)', re.I)
            if any(stale.search(block.text) for block in doc.blocks if block.tag in ("p", "li")):
                yield f"{page}: remove the development instruction to keep the old configVersion."


def check_tree(documents, finalized, number):
    for index in INDEXES:
        if index not in documents:
            yield f"Missing release navigation: {index}."
            continue
        for link in markdown(Path(index).read_bytes()).links:
            if links_to_draft(link):
                yield f"{index}: link to the version page instead of the individual draft {link}."

    # Require both guides for the release being signed and for each open milestone.
    # Older releases predate the split and some have only an upgrade page.
    pages = {(guide, number) for guide in GUIDES}
    for path in sorted(documents):
        note = NOTE.fullmatch(path)
        if not note:
            continue
        if version(note["version"]) > finalized:
            pages.update((guide, note["version"]) for guide in GUIDES)
        elif note["draft"]:
            yield (f"Draft {path} belongs to finalized version {note['version']}. "
                   "Consolidate it or move it and its Nix notice to the next open milestone.")
        else:
            pages.add((note["guide"], note["version"]))

    for guide, page_version in sorted(pages):
        page = f"docs/{guide}/{page_version}.md"
        upcoming = version(page_version) > finalized
        if page in documents:
            yield from check_page(page, guide, page_version, upcoming)
        else:
            hint = f" Run helper/open-release-notes.py {page_version}." if upcoming else ""
            yield f"Missing version page {page}.{hint}"
        for index in ("docs/SUMMARY.md", f"docs/{guide}.md"):
            if index in documents:
                yield from check_navigation(index, page, upcoming)


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


def tree_blobs(revision, directories):
    result = {}
    for entry in git("ls-tree", "-rz", revision, "--", *directories).split(b"\0")[:-1]:
        info, path = os.fsdecode(entry).split("\t", 1)
        result[path] = info.split()[2]
    return result


def release_drafts(prepared, number):
    directories = [f"docs/{guide}/{number}" for guide in GUIDES]
    pages = [f"{directory}.md" for directory in directories]
    # Start at the last development tree. Titles can be edited, and drafts
    # withdrawn or retargeted, while both guides are still collecting notes.
    revisions = git("log", "--first-parent", "--format=%H", prepared, "--", *pages, *directories)
    history = prepared
    for revision in revisions.decode().splitlines():
        blobs = tree_blobs(revision, pages + directories)
        if not all(page in blobs for page in pages) or len(blobs) == len(pages):
            continue
        guides = [markdown(git("cat-file", "blob", blobs[page])) for page in pages]
        if all(guide.has_tbd() and not guide.entries() for guide in guides):
            history = f"{revision}..{prepared}"
            break
    else:
        if git("rev-parse", "--is-shallow-repository").strip() == b"true":
            sys.exit("Missing draft history. Run git fetch --unshallow and retry.")

    # If the version was bumped first, these drafts still need to be consolidated.
    drafts = tree_blobs(prepared, directories)
    # Read the preimage of each removal from the first-parent history. This also
    # sees batches removed before version.nix advanced, and merge commits compare
    # against the branch being released. A moved draft is accounted for at its
    # destination, including when a change moves to a later milestone.
    changes = git("log", "--first-parent", "--format=", "--raw", "-z", "--no-abbrev",
                  "--find-renames", "--diff-filter=DR", history, "--", "docs/upgrading", "docs/release-notes")
    fields = iter(os.fsdecode(changes).split("\0")[:-1])
    for change in fields:
        _, _, old_blob, _, status = change.split()
        path = next(fields)
        destination = NOTE.fullmatch(next(fields)) if status.startswith("R") else None
        # Newest first if the same path was removed and later reused.
        note = NOTE.fullmatch(path)
        if note and note["version"] == number and note["draft"]:
            drafts.setdefault(path, None if destination and destination["draft"] else old_blob)
    return drafts


def check_consolidation(documents, prepared, number):
    remaining = {}
    for path, old_blob in release_drafts(prepared, number).items():
        note = NOTE.fullmatch(path)
        if not old_blob or not note or not note["draft"]:
            continue
        page = f"docs/{note['guide']}/{note['version']}.md"
        if page not in remaining:
            remaining[page] = Counter()
            if page in documents:
                doc = markdown(Path(page).read_bytes())
                footer = note["guide"] == "upgrading" and doc.ends_with_config_version(number)
                remaining[page].update(doc.entries(skip_footer=footer))
        entries = markdown(git("cat-file", "blob", old_blob)).entries()
        if not entries:
            yield f"{path} has no fourth-level heading to match in {page}."
        available = remaining[page]
        for heading, has_text in entries:
            if available[heading, has_text]:
                available[heading, has_text] -= 1
            elif available[heading, not has_text]:
                available[heading, not has_text] -= 1
                if has_text:
                    yield f'{page} has only the heading "{heading}" from {path}. Restore the entry text.'
            else:
                yield f'{page} is missing the heading "{heading}" from {path}.'


def check_published_links(documents, finalized):
    # Render with mdBook itself so its chapter paths, explicit IDs and duplicate
    # heading suffixes are exactly the ones a reader follows. Use the built-in
    # HTML renderer on the signer's machine, without loading repo-defined plugins.
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for path in documents:
            dest = root / "src" / Path(path).relative_to("docs")
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, dest)
        (root / "book.toml").write_text("[build]\ncreate-missing = false\n")
        if subprocess.run(["mdbook", "build", root], stdout=subprocess.DEVNULL).returncode:
            yield "mdBook could not build the release documentation."
            return
        book = (root / "book").resolve()

        @cache
        def rendered(path):
            return Document(path.read_text(), book=True)

        for path in sorted(documents):
            if not path.endswith(".md"):
                continue
            note = NOTE.fullmatch(path)
            released_note = note and not note["draft"] and version(note["version"]) <= finalized
            chapter = book / Path(path).relative_to("docs").with_suffix(".html")
            if not chapter.is_file():
                if released_note:
                    yield f"{path}: version page is missing from the rendered book."
                continue
            for link in rendered(chapter).links:
                url = urlsplit(link)
                if (url.scheme or url.netloc) and url.hostname != "docs.bitcoinix.net":
                    continue
                dest = unquote(url.path)
                if dest.startswith("/") or url.netloc:
                    target = book / dest.lstrip("/")
                else:
                    target = chapter.parent / dest if dest else chapter
                target = target.resolve()
                # Other chapters can also point into a consolidated page or a deleted draft.
                if not released_note and not any(target.is_relative_to(book / guide) for guide in GUIDES):
                    continue
                if target.is_dir():
                    target /= "index.html"
                anchor = unquote(url.fragment)
                if not target.is_relative_to(book) or not target.is_file():
                    yield f"{path}: broken link {link} (missing target)."
                elif anchor and target.suffix == ".html" and anchor not in rendered(target).ids:
                    yield f"{path}: broken link {link} (missing anchor)."


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


def check(number, base):
    finalized = version(number)
    documents = {path for path in paths(None, "docs") if Path(path).is_file()}
    tree_errors = list(check_tree(documents, finalized, number))
    yield from tree_errors
    prepared, parent, previous = release_preparation(finalized)
    # GitHub sends an all-zero "before" SHA on the first push of a branch.
    if base and not re.fullmatch("0+", base):
        yield from check_new_notices(base, version_at(base))
    else:
        # Catch notices added between finalization and signing the tag.
        yield from check_new_notices(prepared, finalized)
        if parent:
            yield from check_new_notices(parent, previous)
    numbers = {number}
    if parent:
        for path in documents | paths(parent, "docs/upgrading", "docs/release-notes"):
            note = NOTE.fullmatch(path)
            if note and previous < version(note["version"]) <= finalized:
                numbers.add(note["version"])
    for page_version in sorted(numbers, key=version):
        yield from check_consolidation(documents, prepared, page_version)
    if not tree_errors:
        yield from check_published_links(documents, finalized)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit("Usage: check-release-notes.sh <finalized-version> [base-commit]")
    os.chdir(Path(__file__).resolve().parent.parent)
    failed = False
    for error in check(sys.argv[1], sys.argv[2] if len(sys.argv) == 3 else None):
        print(f"Error: {error}", file=sys.stderr)
        failed = True
    sys.exit(failed)
