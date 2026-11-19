#!/usr/bin/env python3
"""Build the bitcoinix documentation with its module option list.

`book` builds the documentation of a source tree, by default the current checkout.
`site` builds the documentation site of all releases from FIRST_RELEASE on, as
published at docs.bitcoinix.net: the latest release at `/`, every release at
`/v/<version>/`, `/v/index.html` and `/versions.json` for the version selector.
Every release tag is verified with helper/fetch-release.sh before it is published.

Requires git, mdbook and nix on PATH, and for `site` the tools of fetch-release.sh.
"""

import argparse
from dataclasses import dataclass
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse

FIRST_RELEASE = (0, 1, 6)
TAG_PATTERN = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
OPTIONS_PAGE = Path("docs/options.md")
OPTIONS_BEGIN = "<!-- bitcoinix-options-begin -->\n"
OPTIONS_END = "<!-- bitcoinix-options-end -->"
# The files that mdBook reads (see book.toml); docs/ and theme/ link into assets/
BOOK_FILES = ["book.toml", "docs", "theme", "assets"]
HERE = Path(__file__).resolve().parent
# The output of fetch-release.sh: the verified version and commit
VERIFIED_VERSION = re.compile(r"# bitcoinix release (v[0-9]+\.[0-9]+\.[0-9]+)")
VERIFIED_COMMIT = re.compile(r'\s*url = ".*/archive/([0-9a-f]{40}|[0-9a-f]{64})\.tar\.gz";')
# The systems of the flake outputs
SYSTEMS = ["x86_64-linux", "aarch64-linux"]


class Error(Exception):
    pass


@dataclass(frozen=True, order=True)
class Release:
    version: tuple[int, int, int]

    @classmethod
    def parse(cls, name):
        """Parse a tag name `vX.Y.Z`, or return None."""
        match = TAG_PATTERN.fullmatch(name)
        return cls(tuple(map(int, match.groups()))) if match else None

    @property
    def name(self):
        return ".".join(map(str, self.version))

    @property
    def tag(self):
        return f"v{self.name}"


def log(message):
    print(message, file=sys.stderr, flush=True)


def warn(message):
    # An annotation shows up in the summary of a GitHub Actions run
    log(f"::warning::{message}" if os.environ.get("GITHUB_ACTIONS") == "true" else f"warning: {message}")


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE, **kwargs).stdout


def select_releases(tags, latest):
    """The releases to publish, newest first.

    `latest` is the verified latest release and must be the newest release tag.
    """
    releases = sorted({release for tag in tags if (release := Release.parse(tag))}, reverse=True)
    if Release.parse(f"v{latest}") not in releases:
        raise Error(f"Release tag v{latest} does not exist")
    if releases[0].name != latest:
        raise Error(f"v{latest} is not the latest release tag, {releases[0].tag} is newer")
    if releases[0].version < FIRST_RELEASE:
        raise Error(f"v{latest} is older than the first published release")
    return [release for release in releases if release.version >= FIRST_RELEASE]


def insert_options(page, options):
    """Return the text of options.md with the option list between its markers."""
    if page.count(OPTIONS_BEGIN) != 1 or page.count(OPTIONS_END) != 1:
        raise Error(f"{OPTIONS_PAGE} needs one line {OPTIONS_BEGIN.strip()} and one {OPTIONS_END}")
    start = page.index(OPTIONS_BEGIN) + len(OPTIONS_BEGIN)
    end = page.index(OPTIONS_END)
    if end < start:
        raise Error(f"{OPTIONS_END} comes before {OPTIONS_BEGIN.strip()} in {OPTIONS_PAGE}")
    return page[:start] + "\n" + options.strip("\n") + "\n\n" + page[end:]


def options_system(system=None):
    """The system to build the option list for, by default the current one."""
    if system is None:
        system = run(["nix", "eval", "--impure", "--raw", "--expr", "builtins.currentSystem"])
        hint = "Build in a Linux machine (see dev/macos.md), or pass --system with a Linux builder."
    else:
        hint = ""
    if system not in SYSTEMS:
        raise Error(f"The option list builds only for {' and '.join(SYSTEMS)}, not {system}. {hint}")
    return system


def build_options(flake, system):
    """Build the option list of a flake reference with `#legacyPackages.<system>.docsOptions`."""
    output = run(["nix", "build", "--no-link", "--print-out-paths",
                  f"{flake}#legacyPackages.{system}.docsOptions"])
    return Path(output.strip()).read_text()


def build_book(src, dest, flake, system, title=None):
    """Build the documentation in `src` to `dest`, adding the option list built from `flake`.

    Trees without the markers in options.md (releases before 0.2.0) have no option list.
    """
    page = src / OPTIONS_PAGE
    if page.is_file() and OPTIONS_BEGIN in page.read_text():
        page.write_text(insert_options(page.read_text(), build_options(flake, system)))
    env = os.environ | {"MDBOOK_BOOK__TITLE": title} if title else None
    subprocess.run(["mdbook", "build", "--dest-dir", dest, src], check=True, env=env,
                   stdout=sys.stderr)


def copy_book_files(src, dest):
    for name in BOOK_FILES:
        path = src / name
        if path.is_dir():
            shutil.copytree(path, dest / name, symlinks=True)
        elif path.exists():
            shutil.copy2(path, dest / name)


def tag_commit(repo, release):
    return run(["git", "-C", repo, "rev-parse", "--verify", "--end-of-options",
                f"refs/tags/{release.tag}^{{commit}}"]).strip()


def verify_release(repo, release, fetch_release):
    """Verify a release tag with fetch-release.sh and return its commit, or None if the
    tag is not validly signed by a release key."""
    result = subprocess.run(
        ["bash", fetch_release], text=True, stdout=subprocess.PIPE,
        env=os.environ | {"releaseVersion": release.name,
                          "repoUrl": f"file://{Path(repo).resolve()}"})
    if result.returncode:
        return None
    lines = result.stdout.splitlines()
    versions = [m[1] for line in lines if (m := VERIFIED_VERSION.fullmatch(line))]
    commits = [m[1] for line in lines if (m := VERIFIED_COMMIT.fullmatch(line))]
    if versions != [release.tag] or len(commits) != 1:
        raise Error(f"Unexpected output of {fetch_release} for {release.tag}")
    # fetch-release.sh fetched the tag from `repo` itself, so this only fails if the tag
    # moved in between
    if commits[0] != tag_commit(repo, release):
        raise Error(f"{release.tag} does not point to the verified commit {commits[0]}")
    return commits[0]


def verified_releases(repo, releases, latest, fetch_release):
    """The releases with a validly signed tag and their commits.

    The latest release must verify. An older release that doesn't, e.g. because its key
    was revoked, is left out: tags cannot be deleted, so failing would stop all deployments.
    """
    verified = {}
    for release in releases:
        log(f"Verifying {release.tag}")
        commit = verify_release(repo, release, fetch_release)
        if commit:
            verified[release] = commit
        elif release.name == latest:
            raise Error(f"The latest release tag {release.tag} is not validly signed")
        else:
            warn(f"{release.tag} is not validly signed by a release key, its documentation "
                 "is not published")
    return verified


def extract_commit(repo, commit, dest):
    """Extract the tree of a commit, without any path that leaves `dest`."""
    with subprocess.Popen(["git", "-C", repo, "archive", "--format=tar", f"{commit}^{{tree}}"],
                          stdout=subprocess.PIPE) as process:
        try:
            with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
                archive.extractall(dest, filter="data")
        except BaseException:
            process.kill()
            raise
    if process.returncode:
        raise Error(f"git archive failed for {commit}")


def release_flake(repo, release, commit):
    """A flake reference to the commit of a release tag, which links the option sources to it."""
    query = urllib.parse.urlencode({"ref": f"refs/tags/{release.tag}", "rev": commit})
    return f"git+file://{urllib.parse.quote(str(Path(repo).resolve()))}?{query}"


def add_to_head(page, tags):
    """Insert HTML before the end of the head of a page."""
    head_end = page.find("</head>")
    if head_end == -1:
        raise Error("page has no </head>")
    return page[:head_end] + tags + page[head_end:]


NOINDEX = '<meta name="robots" content="noindex">'


def add_site_tags(book, archived):
    """Add the version selector to the pages of a book. Archived copies are not indexed,
    so that search engines show the pages of the latest release."""
    for path in sorted(book.rglob("*.html")):
        page = path.read_text()
        tags = '<script src="/versions.js" defer></script>\n'
        # mdBook already excludes its print and toc pages
        if archived and NOINDEX not in page:
            tags = NOINDEX + "\n" + tags
        try:
            path.write_text(add_to_head(page, tags))
        except Error as error:
            raise Error(f"{path.relative_to(book)}: {error}") from None


def version_index(releases, latest):
    items = "\n".join(
        f'<li><a href="/v/{html.escape(r.name)}/">v{html.escape(r.name)}</a>'
        + (" (latest)" if r.name == latest else "") + "</li>"
        for r in releases
    )
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>bitcoinix documentation versions</title>
</head>
<body>
<h1>bitcoinix documentation versions</h1>
<p>The <a href="/">documentation of the latest release</a> is at the root of this site.</p>
<ul>
{items}
</ul>
</body>
</html>
"""


def build_site(repo, latest, out, system, fetch_release):
    if out.exists() or out.is_symlink():
        raise Error(f"{out} already exists")
    if not fetch_release.is_file():
        raise Error(f"{fetch_release} does not exist")
    tags = run(["git", "-C", repo, "tag", "--list", "v*"]).split()
    verified = verified_releases(repo, select_releases(tags, latest), latest, fetch_release)
    releases = list(verified)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        site = tmp / "site"
        books = {}
        for release, commit in verified.items():
            log(f"Building the documentation of {release.tag}")
            src = tmp / "src" / release.name
            src.mkdir(parents=True)
            extract_commit(repo, commit, src)
            books[release.name] = tmp / "book" / release.name
            build_book(src, books[release.name], release_flake(repo, release, commit), system,
                       title=f"bitcoinix {release.tag}")
        if any((books[latest] / name).exists() for name in ["v", "versions.json", "versions.js"]):
            raise Error(f"The documentation of v{latest} contains a path that the site uses")
        shutil.copytree(books[latest], site)
        add_site_tags(site, archived=False)
        for name, book in books.items():
            add_site_tags(book, archived=True)
            shutil.copytree(book, site / "v" / name)
        (site / "v" / "index.html").write_text(version_index(releases, latest))
        (site / "versions.json").write_text(json.dumps(
            {"latest": latest, "versions": [r.name for r in releases]}, indent=2) + "\n")
        shutil.copyfile(HERE / "versions.js", site / "versions.js")
        # Only a complete site reaches `out`
        shutil.copytree(site, out)


def build_local_book(src, out, system):
    src = Path(src).resolve()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        copy_book_files(src, tmp)
        build_book(tmp, Path(out).resolve(), f"path:{urllib.parse.quote(str(src))}", system)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    book = commands.add_parser("book", help="build the documentation of a source tree")
    book.add_argument("--src", default=".", help="the source tree (default: .)")
    book.add_argument("--out", default="book", help="the output dir, which mdBook cleans (default: book)")
    book.add_argument("--system", choices=SYSTEMS,
                      help="build the option list for this system (default: the current one)")
    site = commands.add_parser("site", help="build the documentation site of all releases")
    site.add_argument("--repo", required=True, help="a git repo with the release tags")
    site.add_argument("--latest", required=True,
                      help="the verified latest release, e.g. 0.2.0; must be the newest release tag")
    site.add_argument("--out", required=True, type=Path, help="the output dir, which must not exist")
    site.add_argument("--fetch-release", required=True, type=Path,
                      help="the trusted helper/fetch-release.sh that verifies the release tags")
    site.add_argument("--system", choices=SYSTEMS,
                      help="build the option lists for this system (default: the current one)")
    args = parser.parse_args()
    try:
        if args.command == "book":
            build_local_book(args.src, args.out, options_system(args.system))
        else:
            build_site(args.repo, args.latest, args.out, options_system(args.system),
                       args.fetch_release.resolve())
    except (Error, subprocess.CalledProcessError, tarfile.TarError) as error:
        sys.exit(f"error: {error}")


if __name__ == "__main__":
    main()
