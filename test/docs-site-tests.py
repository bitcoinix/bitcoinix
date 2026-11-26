"""Tests for helper/docs/build.py, with real git and mdBook, a fake nix and a fake
fetch-release.sh.

Usage: python3 test/docs-site-tests.py helper/docs
"""

import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

DOCS_TOOLS = Path(sys.argv.pop(1)).resolve()
_spec = importlib.util.spec_from_file_location("docs_build", DOCS_TOOLS / "build.py")
docs_site = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(docs_site)

GIT_ENV = {
    "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.com",
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
}
OPTIONS = "## foo\\.bar {#opt-foo.bar}\n\nThe foo option\\.\n"
OPTIONS_PAGE = """# Module options

Intro

<!-- bitcoinix-options-begin -->
Placeholder
<!-- bitcoinix-options-end -->
"""


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, text=True,
                          stdout=subprocess.PIPE, env=os.environ | GIT_ENV).stdout.strip()


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class Tmp(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        # Fake nix: log the calls and build the option list from $OPTIONS_FILE
        bin = self.tmp / "bin"
        bin.mkdir()
        self.nix_log = self.tmp / "nix.log"
        self.options_file = self.tmp / "options.md"
        self.options_file.write_text(OPTIONS)
        nix = bin / "nix"
        nix.write_text(f"""#!{shutil.which("bash")}
printf '%s\\n' "$*" >> {self.nix_log}
case $1 in
    eval) printf '%s' "${{FAKE_SYSTEM:-x86_64-linux}}" ;;
    build) echo {self.options_file} ;;
    *) exit 1 ;;
esac
""")
        nix.chmod(0o755)
        # Fake fetch-release.sh: log the calls, fail for the versions in $FAKE_UNSIGNED and
        # print the expression with the commit of the tag, or $FAKE_COMMIT
        self.fetch_log = self.tmp / "fetch.log"
        self.fetch_release = self.tmp / "fetch-release.sh"
        self.fetch_release.write_text(f"""
printf '%s %s\\n' "$releaseVersion" "$repoUrl" >> {self.fetch_log}
case " ${{FAKE_UNSIGNED:-}} " in
    *" $releaseVersion "*) echo "Error: signature verification failed" >&2; exit 1 ;;
esac
commit=${{FAKE_COMMIT:-$(git -C "${{repoUrl#file://}}" rev-parse "refs/tags/v$releaseVersion^{{commit}}")}}
cat <<EOF
# bitcoinix release v$releaseVersion
builtins.fetchTarball {{
  url = "$repoUrl/archive/$commit.tar.gz";
  sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
}}
EOF
""")
        self.env = os.environ | {"PATH": f"{bin}:{os.environ['PATH']}"}

    def nix_builds(self):
        if not self.nix_log.exists():
            return []
        return [line.split()[-1] for line in self.nix_log.read_text().splitlines()
                if line.startswith("build ")]

    def verified(self):
        if not self.fetch_log.exists():
            return []
        return [line.split() for line in self.fetch_log.read_text().splitlines()]

    def site_py(self, *args, check=True):
        try:
            return subprocess.run([sys.executable, DOCS_TOOLS / "build.py", *args], env=self.env,
                                  check=check, text=True, capture_output=True)
        except subprocess.CalledProcessError as error:
            self.fail(f"{error}\nstdout:\n{error.stdout}\nstderr:\n{error.stderr}")

    def make_book(self, root, options=False):
        write(root / "book.toml", '[book]\ntitle = "bitcoinix"\nsrc = "docs"\n'
              'description = "Nodes & more"\n[build]\ncreate-missing = false\n'
              '[output.html.redirect]\n"/old-intro.html" = "introduction.html"\n')
        summary = "# Summary\n\n[Introduction](introduction.md)\n"
        if options:
            summary += ("- [Module options](options.md)\n- [Upgrading](upgrading.md)\n"
                        "  - [Version 0.2.0](upgrading/0.2.0.md)\n")
            write(root / "docs/options.md", OPTIONS_PAGE)
            write(root / "docs/upgrading.md", "# Upgrading\n\n> A note\n\n" + " ".join(
                ["Words"] * 40) + "\n")
            write(root / "docs/upgrading/0.2.0.md", "# Upgrading to 0.2.0\n")
            write(root / "assets/logo.png", "logo")
        write(root / "docs/SUMMARY.md", summary)
        write(root / "docs/introduction.md", "# Introduction\n\nText with `code` & more\n")
        write(root / "docs/install.md", "# Install\n")


class SelectReleases(unittest.TestCase):
    def names(self, tags, latest):
        return [r.name for r in docs_site.select_releases(tags, latest)]

    def test_selects_releases_from_the_first_published_one(self):
        tags = ["forked", "v0.0.92", "v0.1.5", "v0.1.6", "v0.2.0", "v0.2.0-rc1",
                "v01.2.3", "v0.2", "vv0.3.0", "v0.10.0", "v0.9.0"]
        self.assertEqual(self.names(tags, "0.10.0"), ["0.10.0", "0.9.0", "0.2.0", "0.1.6"])

    def test_rejects_a_latest_release_that_is_not_the_newest_tag(self):
        with self.assertRaisesRegex(docs_site.Error, "v0.2.1 is newer"):
            docs_site.select_releases(["v0.1.6", "v0.2.0", "v0.2.1"], "0.2.0")

    def test_rejects_unknown_or_malformed_latest_releases(self):
        for latest in ["0.2.1", "0.2", "v0.2.0", "0.2.0 ", "../0.2.0", ""]:
            with self.subTest(latest=latest), self.assertRaisesRegex(docs_site.Error, "does not exist"):
                docs_site.select_releases(["v0.1.6", "v0.2.0"], latest)

    def test_rejects_a_latest_release_before_the_first_published_one(self):
        with self.assertRaisesRegex(docs_site.Error, "older than the first"):
            docs_site.select_releases(["v0.1.4", "v0.1.5"], "0.1.5")


class Pages(unittest.TestCase):
    def test_inserts_the_options_between_the_markers(self):
        page = docs_site.insert_options(OPTIONS_PAGE, "\n" + OPTIONS + "\n\n")
        self.assertEqual(page, OPTIONS_PAGE.replace("Placeholder\n", "\n" + OPTIONS + "\n"))

    def test_rejects_missing_repeated_or_swapped_markers(self):
        begin, end = docs_site.OPTIONS_BEGIN, docs_site.OPTIONS_END
        for page in ["# Options\n", begin, end, begin + end + begin + end, end + "\n" + begin]:
            with self.subTest(page=page), self.assertRaises(docs_site.Error):
                docs_site.insert_options(page, OPTIONS)

    def test_adds_tags_before_the_end_of_the_head(self):
        self.assertEqual(docs_site.add_to_head("<head><title>x</title></head><p></head>", "<x>"),
                         "<head><title>x</title><x></head><p></head>")
        with self.assertRaises(docs_site.Error):
            docs_site.add_to_head("<p>no head</p>", "<x>")


class Site(Tmp):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls._template_tmp = Path(tempfile.mkdtemp())
        cls._template_repo = cls._template_tmp / "repo"
        cls._template_repo.mkdir()
        git(cls._template_repo, "init", "-q")
        cls._make_book(cls._template_repo)
        git(cls._template_repo, "add", "-A")
        git(cls._template_repo, "commit", "-qm", "0.1.5")
        git(cls._template_repo, "tag", "-am", "v0.1.5", "v0.1.5")
        write(cls._template_repo / "docs/introduction.md", "# Introduction\n\nRelease 0.1.6\n")
        git(cls._template_repo, "commit", "-qam", "0.1.6")
        git(cls._template_repo, "tag", "-am", "v0.1.6", "v0.1.6")
        cls._make_book(cls._template_repo, options=True)
        git(cls._template_repo, "add", "-A")
        git(cls._template_repo, "commit", "-qm", "0.2.0")
        git(cls._template_repo, "tag", "-am", "v0.2.0", "v0.2.0")
        cls._shared_site_020 = None

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._template_tmp)
        super().tearDownClass()

    def shared_site_020(self):
        """Build the unmodified 0.2.0 site once and reuse it for read-only assertions."""
        cls = type(self)
        if cls._shared_site_020 is None:
            out = cls._template_tmp / "site-0.2.0"
            self.site_py("site", "--repo", cls._template_repo, "--latest", "0.2.0",
                         "--out", out, "--fetch-release", self.fetch_release)
            cls._shared_site_020 = (
                out, cls._template_repo, self.verified(), self.nix_builds(),
            )
        return cls._shared_site_020

    @staticmethod
    def _make_book(root, options=False):
        Tmp.make_book(None, root, options=options)

    def setUp(self):
        super().setUp()
        self.repo = self.tmp / "repo"
        shutil.copytree(self._template_repo, self.repo)
        self.out = self.tmp / "site"

    def build_site(self, latest, check=True):
        return self.site_py("site", "--repo", self.repo, "--latest", latest, "--out", self.out,
                            "--fetch-release", self.fetch_release, check=check)

    def html_files(self, root):
        return sorted(p for p in root.rglob("*.html") if p.parent != root / "v")

    def test_extracts_archives_with_trailing_padding(self):
        # Run real git, then append valid tar padding exceeding even a 64 KiB
        # kernel page. The writer cannot finish until the reader drains the pipe.
        producer = """
import signal
import subprocess
import sys
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
signal.alarm(30)
subprocess.run(sys.argv[2:], check=True)
sys.stdout.buffer.write(b'\\0' * (1024 * 1024))
sys.stdout.buffer.flush()
sys.exit(int(sys.argv[1]))
"""
        popen = subprocess.Popen
        for exit_code in (0, 7):
            with self.subTest(exit_code=exit_code):
                def padded_archive(args, **kwargs):
                    return popen([sys.executable, "-c", producer, str(exit_code), *args],
                                 pipesize=4096, **kwargs)

                dest = self.tmp / f"extracted-{exit_code}"
                with mock.patch.object(subprocess, "Popen", side_effect=padded_archive):
                    if exit_code:
                        # A complete archive must not hide a failing producer.
                        with self.assertRaisesRegex(docs_site.Error, "git archive failed"):
                            docs_site.extract_commit(self.repo, "v0.2.0", dest)
                    else:
                        docs_site.extract_commit(self.repo, "v0.2.0", dest)
                self.assertEqual((dest / "docs/introduction.md").read_text(),
                                 (self.repo / "docs/introduction.md").read_text())

    def test_builds_the_latest_release_at_the_root_and_each_release_under_v(self):
        out, repo, verified, nix_builds = self.shared_site_020()

        self.assertIn(f"<title>{docs_site.HOME_TITLE}</title>", (out / "index.html").read_text())
        self.assertIn('id="opt-foo.bar"', (out / "options.html").read_text())
        self.assertNotIn("Placeholder", (out / "options.html").read_text())
        self.assertEqual(sorted(p.name for p in (out / "v").iterdir()), ["0.1.6", "0.2.0", "index.html"])
        self.assertIn("<title>Version 0.2.0 - Upgrading - bitcoinix docs</title>",
                      (out / "upgrading/0.2.0.html").read_text())
        self.assertIn("<title>Version 0.2.0 - Upgrading - bitcoinix v0.2.0</title>",
                      (out / "v/0.2.0/upgrading/0.2.0.html").read_text())
        self.assertIn('id="opt-foo.bar"', (out / "v/0.2.0/options.html").read_text())
        old = (out / "v/0.1.6/index.html").read_text()
        self.assertIn("<title>Introduction - bitcoinix v0.1.6</title>", old)
        self.assertIn("Release 0.1.6", old)
        self.assertFalse((out / "v/0.1.6/options.html").exists())

        script = '<script src="/versions.js" defer></script>'
        noindex = '<meta name="robots" content="noindex">'
        root_pages = [p for p in self.html_files(out) if out / "v" not in p.parents]
        archived_pages = [p for p in self.html_files(out) if out / "v" in p.parents]
        self.assertTrue(root_pages and archived_pages)
        for page in root_pages:
            text = page.read_text()
            self.assertEqual(text.count(script), 1, page)
            # mdBook marks its print and toc pages itself
            if page.name not in ["print.html", "toc.html"]:
                self.assertNotIn(noindex, text, page)
        for page in archived_pages:
            text = page.read_text()
            self.assertEqual(text.count(script), 1, page)
            self.assertEqual(text.count(noindex), 1, page)
            self.assertLess(text.index(script), text.index("</head>"), page)

        self.assertEqual(json.loads((out / "versions.json").read_text()),
                         {"latest": "0.2.0", "versions": ["0.2.0", "0.1.6"]})
        self.assertEqual((out / "versions.js").read_text(), (DOCS_TOOLS / "versions.js").read_text())
        index = (out / "v/index.html").read_text()
        self.assertEqual(re.findall(r'href="(/v/[^"]*)"', index), ["/v/0.2.0/", "/v/0.1.6/"])

        # Each published release is verified with fetch-release.sh, from the repo itself
        repo_url = f"file://{repo.resolve()}"
        self.assertEqual(verified, [["0.2.0", repo_url], ["0.1.6", repo_url]])

        # Only v0.2.0 has an option list, built from the commit of its tag
        commit = git(repo, "rev-parse", "v0.2.0^{commit}")
        self.assertEqual(nix_builds, [
            f"git+file://{repo.resolve()}?ref=refs%2Ftags%2Fv0.2.0&rev={commit}"
            "#legacyPackages.x86_64-linux.docsOptions"
        ])

    def test_adds_a_sitemap_and_search_and_link_preview_tags(self):
        out, _, _, _ = self.shared_site_020()
        site = docs_site.SITE_URL
        self.assertEqual(re.findall(r"<loc>([^<]*)</loc>", (out / "sitemap.xml").read_text()), [
            f"{site}/", f"{site}/options.html", f"{site}/upgrading/0.2.0.html",
            f"{site}/upgrading.html",
        ])
        self.assertEqual((out / "robots.txt").read_text(),
                         f"User-agent: *\nDisallow:\n\nSitemap: {site}/sitemap.xml\n")
        self.assertEqual((out / docs_site.SOCIAL_IMAGE_PATH).read_text(), "logo")
        # Redirect pages keep the canonical URL of their target
        redirect = (out / "old-intro.html").read_text()
        self.assertEqual(re.findall(r'<link rel="canonical" href="([^"]*)">', redirect),
                         ["introduction.html"])
        self.assertIn("<title>Redirecting...</title>", redirect)
        self.assertNotIn("og:", redirect)
        self.assertIn(docs_site.NOINDEX, (out / "v/0.1.6/old-intro.html").read_text())

        def tags(path):
            text = (out / path).read_text()
            head = text[:text.index("</head>")]
            return {
                "canonical": re.findall(r'<link rel="canonical" href="([^"]*)">', head),
                "description": re.findall(r'<meta name="description" content="([^"]*)">', head),
                **{key: re.findall(rf'<meta property="og:{key}" content="([^"]*)">', head)
                   for key in ["title", "url", "image"]},
            }

        # The first chapter has the URL of the site root
        for path in ["index.html", "introduction.html"]:
            self.assertEqual(tags(path), {
                "canonical": [f"{site}/"], "description": ["Text with code &amp; more"],
                "title": [docs_site.HOME_TITLE], "url": [f"{site}/"],
                "image": [f"{site}/{docs_site.SOCIAL_IMAGE_PATH}"],
            }, path)
        # The description skips block quotes and is shortened
        upgrading = tags("upgrading.html")
        self.assertEqual(upgrading["canonical"], [f"{site}/upgrading.html"])
        self.assertTrue(upgrading["description"][0].startswith("Words Words"))
        self.assertTrue(upgrading["description"][0].endswith("Words…"))
        self.assertLessEqual(len(upgrading["description"][0]), docs_site.DESCRIPTION_LENGTH)
        # Without a paragraph, the description of the book
        self.assertEqual(tags("upgrading/0.2.0.html")["description"], ["Nodes &amp; more"])
        self.assertEqual(tags("upgrading/0.2.0.html")["title"], ["Version 0.2.0 - Upgrading"])
        self.assertIn("<title>bitcoinix docs</title>", (out / "print.html").read_text())
        # Pages that are not indexed have no tags
        for path in ["print.html", "toc.html", "404.html"]:
            self.assertEqual(tags(path)["canonical"] + tags(path)["url"], [], path)
        # Archived pages link to themselves, but not as canonical pages
        self.assertEqual(tags("v/0.1.6/index.html"), {
            "canonical": [], "description": ["Release 0.1.6"],
            "title": ["Introduction"], "url": [f"{site}/v/0.1.6/"],
            "image": [f"{site}/{docs_site.SOCIAL_IMAGE_PATH}"],
        })
        self.assertEqual(tags("v/0.2.0/upgrading.html")["url"], [f"{site}/v/0.2.0/upgrading.html"])

    def test_fails_when_the_latest_release_is_not_the_newest_tag(self):
        git(self.repo, "tag", "-am", "v0.2.1", "v0.2.1")
        result = self.build_site("0.2.0", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("v0.2.1 is newer", result.stderr)
        self.assertFalse(self.out.exists())

    def test_leaves_out_older_releases_that_fail_verification(self):
        # A lightweight tag, pushed after a newer release
        git(self.repo, "tag", "v0.1.7", "v0.1.6^{}")
        self.env["FAKE_UNSIGNED"] = "0.1.7"
        result = self.build_site("0.2.0")
        self.assertIn("v0.1.7 is not validly signed", result.stderr)
        self.assertEqual(json.loads((self.out / "versions.json").read_text()),
                         {"latest": "0.2.0", "versions": ["0.2.0", "0.1.6"]})
        self.assertEqual(sorted(p.name for p in (self.out / "v").iterdir()),
                         ["0.1.6", "0.2.0", "index.html"])
        self.assertNotIn("0.1.7", (self.out / "v/index.html").read_text())

    def test_fails_when_the_latest_release_fails_verification(self):
        self.env["FAKE_UNSIGNED"] = "0.2.0"
        result = self.build_site("0.2.0", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("latest release tag v0.2.0 is not validly signed", result.stderr)
        self.assertFalse(self.out.exists())
        # Nothing of an unverified release is evaluated
        self.assertEqual(self.nix_builds(), [])

    def test_fails_unless_the_tag_points_to_the_verified_commit(self):
        old = git(self.repo, "rev-parse", "v0.1.6^{commit}")
        for commit, error in [(old, f"does not point to the verified commit {old}"),
                              ("main", "Unexpected output")]:
            with self.subTest(commit=commit):
                self.env["FAKE_COMMIT"] = commit
                result = self.build_site("0.2.0", check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                self.assertFalse(self.out.exists())
                self.assertEqual(self.nix_builds(), [])

    def test_fails_without_fetch_release(self):
        self.fetch_release.unlink()
        result = self.build_site("0.2.0", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fetch-release.sh does not exist", result.stderr)
        self.assertFalse(self.out.exists())

    def test_never_writes_into_an_existing_dir(self):
        self.out.mkdir()
        result = self.build_site("0.2.0", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.out.iterdir()), [])

    def test_fails_without_option_list_markers(self):
        write(self.repo / "docs/options.md", "# Module options\n\n<!-- bitcoinix-options-begin -->\n")
        git(self.repo, "commit", "-qam", "0.2.1")
        git(self.repo, "tag", "-am", "v0.2.1", "v0.2.1")
        result = self.build_site("0.2.1", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("needs one line", result.stderr)

    def test_rejects_links_out_of_the_release_tree(self):
        for target, error in [("../../..", "outside the destination"),
                              ("/etc", "link to an absolute path")]:
            with self.subTest(target=target):
                link = self.repo / "docs/escape"
                link.unlink(missing_ok=True)
                link.symlink_to(target)
                git(self.repo, "add", "-A")
                git(self.repo, "commit", "-qm", f"link to {target}")
                git(self.repo, "tag", "-fam", "v0.2.1", "v0.2.1")
                result = self.build_site("0.2.1", check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertFalse(self.out.exists())


class Book(Tmp):
    def test_builds_a_source_tree_without_changing_it(self):
        src = self.tmp / "src"
        self.make_book(src, options=True)
        out = self.tmp / "book"
        self.site_py("book", "--src", src, "--out", out)
        self.assertIn('id="opt-foo.bar"', (out / "options.html").read_text())
        self.assertNotIn("/versions.js", (out / "options.html").read_text())
        self.assertEqual((src / "docs/options.md").read_text(), OPTIONS_PAGE)
        self.assertEqual(self.nix_builds(),
                         [f"path:{src.resolve()}#legacyPackages.x86_64-linux.docsOptions"])

    def test_builds_only_for_the_systems_of_the_flake(self):
        src = self.tmp / "src"
        self.make_book(src, options=True)
        self.env["FAKE_SYSTEM"] = "aarch64-darwin"
        result = self.site_py("book", "--src", src, "--out", self.tmp / "book", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not aarch64-darwin", result.stderr)
        self.assertIn("dev/macos.md", result.stderr)
        self.assertEqual(self.nix_builds(), [])
        # With a Linux builder
        self.site_py("book", "--src", src, "--out", self.tmp / "book", "--system", "aarch64-linux")
        self.assertEqual(self.nix_builds(),
                         [f"path:{src.resolve()}#legacyPackages.aarch64-linux.docsOptions"])


if __name__ == "__main__":
    unittest.main()
