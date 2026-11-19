#!/usr/bin/env python3
"""Create the version pages and navigation for a milestone's first draft."""

from pathlib import Path
import re
import subprocess
import sys


VERSION = r"[0-9]+\.[0-9]+\.[0-9]+"
ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"


def version(value):
    if not re.fullmatch(VERSION, value):
        sys.exit(f"Expected a version of the form X.Y.Z, got {value!r}")
    return tuple(map(int, value.split(".")))


def add_version(text, guide, number, *, summary):
    """Insert the new entry in numeric order, preserving older bookmark anchors."""
    lines = text.splitlines(keepends=True)
    pattern = re.compile(rf"^\s*-\s+.*?\]\((?:\./)?{guide}/({VERSION})\.md\)")
    entries = [(i, match[1]) for i, line in enumerate(lines) if (match := pattern.search(line))]
    if any(v == number for _, v in entries):
        return text
    if entries:
        insert = next((i for i, v in entries if version(v) < version(number)), entries[-1][0] + 1)
    else:
        section = (rf"^- \[[^\]]+\]\((?:\./)?{guide}\.md\)$" if summary else r"^## Versions$")
        insert = next((i + 1 for i, line in enumerate(lines) if re.fullmatch(section, line.rstrip())), None)
        if insert is None:
            sys.exit(f"Could not find the {guide} section in {'docs/SUMMARY.md' if summary else f'docs/{guide}.md'}.")
        if not summary:
            lines.insert(insert, "\n")
            insert += 1
    entry = f"- [{number}]({guide}/{number}.md)"
    lines.insert(insert, f"  {entry}\n" if summary else f"{entry} (upcoming)\n")
    return "".join(lines)


def placeholder(guide, number):
    title, notes = ("Release notes", "release notes") if guide == "release-notes" else (
        "Upgrading to config version", "upgrade notes")
    text = f"# {title} {number}\n\nTBD. The {notes} will be consolidated here for the {number} release.\n"
    if guide == "upgrading":
        text += (f"\nWhile {number} is in development, keep `nix-bitcoin.configVersion` at the latest finalized release.\n"
                 f"After migrating to the finalized release, set `nix-bitcoin.configVersion = \"{number}\";`.\n")
    url = f"https://github.com/bitcoinix/bitcoinix/tree/master/docs/{guide}"
    if any((DOCS / guide / number).glob("*.md")):
        return text + f"\nSee the [draft {notes} on GitHub]({url}/{number}).\n"
    # Git has no empty directories. This link also works before this guide's first draft.
    return text + f"\nDrafts will appear under `{number}/` in the [{notes} directory on GitHub]({url}).\n"


def main(number):
    released = subprocess.check_output(["nix", "eval", "--raw", "--file", ROOT / "version.nix"], text=True)
    if version(number) <= version(released):
        sys.exit(f"Choose an open milestone newer than the finalized version {released}.")
    summary = DOCS / "SUMMARY.md"
    original = summary.read_text()
    navigation = original
    changes = {}
    for guide in ("upgrading", "release-notes"):
        page = DOCS / guide / f"{number}.md"
        if not page.exists():
            changes[page] = placeholder(guide, number)
        index = DOCS / f"{guide}.md"
        before = index.read_text()
        after = add_version(before, guide, number, summary=False)
        if after != before:
            changes[index] = after
        navigation = add_version(navigation, guide, number, summary=True)
    if navigation != original:
        changes[summary] = navigation
    for path, content in changes.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        print(path.relative_to(ROOT))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: helper/open-release-notes.py <version>")
    main(sys.argv[1])
