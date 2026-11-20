#!/usr/bin/env bash
# Offline tests for helper/make-release.sh.
#
# Uses throwaway ssh keys and a local bare repository as `origin`, so no network
# access and no maintainer key are needed. The origin rejects every push that the
# test does not make itself, which proves that the script never publishes.
# See "Checks without a VM" in test/README.md for the Nix shell command.
set -euo pipefail

scriptDir=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
repoRoot=$scriptDir/..

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Isolate from the developer's git config: a global commit.gpgsign or signingkey
# would make the fixture commits try to use a real maintainer key.
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL=$tmp/gitconfig

mkkey() { ssh-keygen -q -t ed25519 -N '' -C "$1" -f "$tmp/$1"; }
mkkey trusted
mkkey untrusted

signers=$tmp/allowed_signers
printf 'a@example.com namespaces="git" %s\n' "$(cat "$tmp/trusted.pub")" > "$signers"
revoked=$tmp/revoked_keys
echo '# no revoked keys' > "$revoked"

cat > "$GIT_CONFIG_GLOBAL" <<EOF
[user]
    name = bitcoinix test
    email = test@example.com
    signingkey = $tmp/trusted.pub
[commit]
    gpgsign = false
[tag]
    gpgsign = false
[gpg]
    format = ssh
[init]
    defaultBranch = master
EOF

failures=0
pass() { printf 'ok     %s\n' "$1"; }
fail() { printf 'FAIL   %s\n' "$1"; failures=$((failures + 1)); }

origin=$tmp/origin.git
work=$tmp/work
allowPush=$tmp/allow-push
unexpectedPush=$tmp/unexpected-push
out=$tmp/stdout
err=$tmp/stderr
exampleFiles=(
    examples/configuration.nix
    examples/flakes/flake.nix
    examples/colmena/flake.nix
    examples/container/flake.nix
)

# Recreate origin and a work clone with one pushed commit on master
new_world() {
    rm -rf "$origin" "$work"
    git init -q --bare "$origin"
    # Only pushes made by `push_to_origin` get through
    cat > "$origin/hooks/pre-receive" <<EOF
#!/bin/sh
[ -e "$allowPush" ] || { touch "$unexpectedPush"; exit 1; }
EOF
    chmod +x "$origin/hooks/pre-receive"

    git init -q "$work"
    mkdir -p "$work/helper"
    cp "$repoRoot/helper/"{make-release.sh,fetch-release.sh,check-release-notes.sh,check-release-notes.py,open-release-notes.py} "$work/helper/"
    local example
    for example in "${exampleFiles[@]}"; do
        mkdir -p "$work/${example%/*}"
        cp "$repoRoot/$example" "$work/$example"
    done
    mkdir "$work/docs"
    printf '# Summary\n\n- [Upgrading](upgrading.md)\n- [Release notes](release-notes.md)\n' > "$work/docs/SUMMARY.md"
    printf '# Upgrading\n\n## Versions\n' > "$work/docs/upgrading.md"
    printf '# Release notes\n\n## Versions\n' > "$work/docs/release-notes.md"
    echo '"0.0.0"' > "$work/version.nix"
    prepare_notes 0.1.0
    set_release_version 0.1.0
    echo content > "$work/file"
    git -C "$work" add -A
    git -C "$work" commit -q -m "initial commit"
    git -C "$work" remote add origin "$origin"
    push_to_origin master
}

open_notes() {
    "$work/helper/open-release-notes.py" "$1" >/dev/null
}

finish_indexes() {
    local guide
    for guide in upgrading release-notes; do
        sed -i "\\|($guide/$1.md)|s/ (upcoming)$//" "$work/docs/$guide.md"
    done
}

footer() {
    cat <<EOF

After migrating your configuration, set \`bitcoinix.configVersion = "$1";\`.
EOF
}

prepare_notes() {
    open_notes "$1"
    printf '# Release notes %s\n' "$1" > "$work/docs/release-notes/$1.md"
    printf '# Upgrading to config version %s\n' "$1" > "$work/docs/upgrading/$1.md"
    footer "$1" >> "$work/docs/upgrading/$1.md"
    finish_indexes "$1"
    git -C "$work" add docs
}

set_release_version() {
    printf '"%s"\n' "$1" > "$work/version.nix"
    local example
    for example in "${exampleFiles[@]}"; do
        sed -i \
            -e "s/configVersion = \"[^\"]*\";/configVersion = \"$1\";/" \
            -e "s|github:bitcoinix/bitcoinix/v[0-9.]*|github:bitcoinix/bitcoinix/v$1|" \
            "$work/$example"
    done
}

push_to_origin() {
    touch "$allowPush"
    git -C "$work" push -q origin "$@"
    rm "$allowPush"
}

# Add a commit to the work clone and publish it
add_commit() {
    echo "$1" > "$work/file"
    git -C "$work" commit -q -a -m "$1"
    push_to_origin master
}

# Publish a release that was made with the script
release() {
    prepare_notes "$1"
    set_release_version "$1"
    add_commit "prepare $1"
    run_make --yes "$1" || { echo "setup release $1 failed"; cat "$err"; exit 1; }
    push_to_origin "v$1"
}

origin_refs() { git -C "$origin" for-each-ref; }

# run_make [args...] -> captures stdout in $out, stderr in $err
run_make() {
    # No stdin: the script must never need a terminal when it is not given one
    allowedSigners=$signers revokedKeys=$revoked bash "$work/helper/make-release.sh" "$@" \
        >"$out" 2>"$err" </dev/null
}

has_tag() { git -C "$work" rev-parse -q --verify "refs/tags/v$1" >/dev/null; }

#――― must pass ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――

new_world
before=$(origin_refs)
if run_make --yes 0.1.0; then
    pass "release is created"
else
    fail "release is created"; sed 's/^/       /' "$err"
fi

if [[ $(git -C "$work" cat-file -t refs/tags/v0.1.0) == tag ]]; then
    pass "tag is annotated"
else
    fail "tag is annotated"
fi

if [[ $(git -C "$work" rev-parse 'v0.1.0^{commit}') == "$(git -C "$work" rev-parse HEAD)" ]]; then
    pass "tag points at HEAD"
else
    fail "tag points at HEAD"
fi

if git -C "$work" -c gpg.ssh.allowedSignersFile="$signers" tag -v v0.1.0 >/dev/null 2>&1; then
    pass "tag is signed by a listed key"
else
    fail "tag is signed by a listed key"
fi

if [[ $(origin_refs) == "$before" && ! -e $unexpectedPush ]]; then
    pass "nothing is pushed"
else
    fail "nothing is pushed"
fi

if grep -qF 'git push origin v0.1.0' "$out"; then
    pass "push command is printed"
else
    fail "push command is printed"; cat "$out"
fi

# v0.10.0 sorts before v0.9.0 as a string
new_world
release 0.9.0
prepare_notes 0.10.0
set_release_version 0.10.0
add_commit second
if run_make --yes 0.10.0 && has_tag 0.10.0; then
    pass "0.10.0 is newer than 0.9.0"
else
    fail "0.10.0 is newer than 0.9.0"; sed 's/^/       /' "$err"
fi

#――― must fail ―――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――

# expect_failure <description> <regex expected in stderr> <script args...>
# The state it ran against is left in place, so callers can assert on it.
expect_failure() {
    expect_rejection "$1" "$2" run_make "${@:3}"
}

expect_rejection() {
    if "${@:3}"; then
        fail "$1 (accepted)"
    elif grep -qiE -- "$2" "$err"; then
        pass "$1"
    else
        fail "$1 (rejected, but not for the expected reason)"
        sed 's/^/       /' "$err"
    fi
}

run_notes() {
    bash "$work/helper/check-release-notes.sh" "$@" >"$out" 2>"$err"
}

new_world
git -C "$work" switch -q -c other
expect_failure "wrong branch" "releases are cut from" --yes 0.1.0
has_tag 0.1.0 && fail "wrong branch: no tag is left behind"

new_world
echo changed > "$work/file"
expect_failure "dirty tracked file" "uncommitted" --yes 0.1.0
has_tag 0.1.0 && fail "dirty tracked file: no tag is left behind"

# An untracked file does not matter
new_world
echo scratch > "$work/untracked"
if run_make --yes 0.1.0; then
    pass "untracked file is ignored"
else
    fail "untracked file is ignored"; sed 's/^/       /' "$err"
fi

new_world
add_commit second
git -C "$work" reset -q --hard HEAD~1
expect_failure "behind origin" "git pull --ff-only" --yes 0.1.0

new_world
echo second > "$work/file"
git -C "$work" commit -q -a -m second
expect_failure "ahead of origin" "not at origin/master" --yes 0.1.0

new_world
git -C "$work" tag v0.1.0
expect_failure "tag exists locally" "already exists locally" --yes 0.1.0

# The local copy is gone, so only the remote can reject it
new_world
git -C "$work" tag v0.1.0
push_to_origin v0.1.0
git -C "$work" tag -d v0.1.0 >/dev/null
expect_failure "tag exists on the remote" "already exists on" --yes 0.1.0

new_world
release 0.2.0
add_commit second
expect_failure "version lower than the latest release" "not greater" --yes 0.1.0
has_tag 0.1.0 && fail "version lower than the latest release: no tag is left behind"

new_world
expect_failure "version with a leading v" "invalid version" --yes v0.1.0
expect_failure "pre-release version" "invalid version" --yes 0.1.0-rc1
expect_failure "version with one part" "invalid version" --yes 1
expect_failure "version with four parts" "invalid version" --yes 0.1.0.1
expect_failure "version with shell metacharacters" "invalid version" --yes '0.1.0; id'
expect_failure "empty version" "missing|invalid version" --yes ''
expect_failure "no version" "missing" --yes
expect_failure "two versions" "more than one" --yes 0.1.0 0.2.0
expect_failure "unknown option" "unknown option" --force 0.1.0
if [[ -z $(git -C "$work" tag --list) ]]; then
    pass "invalid versions: no tag is left behind"
else
    fail "invalid versions: no tag is left behind"
fi

new_world
echo '"0.0.9"' > "$work/version.nix"
add_commit "old release version"
expect_failure "release version not finalized" "Set version.nix to 0.1.0" --yes 0.1.0
has_tag 0.1.0 && fail "release version not finalized: no tag is left behind"

new_world
rm "$work/version.nix"
add_commit "missing release marker"
expect_failure "missing release marker" "Missing release marker: version.nix" --yes 0.1.0
has_tag 0.1.0 && fail "missing release marker: no tag is left behind"

new_world
mkdir -p "$work/docs/upgrading/0.1.0/nested" "$work/docs/release-notes/0.0.9" "$work/docs/upgrading/0.1.10"
for draft in docs/upgrading/0.1.0/{late.md,nested/step.md,missed.markdown} docs/release-notes/0.0.9/late.md docs/upgrading/0.1.10/future.md; do
    echo '#### A draft' > "$work/$draft"
    git -C "$work" add "$draft"
done
echo 'TBD. Notes will be consolidated here.' > "$work/docs/release-notes/0.1.0.md"
git -C "$work" add docs/release-notes/0.1.0.md
add_commit "unconsolidated release notes"
expect_failure "drafts in a finalized version" "Draft docs/upgrading/0.1.0/late.md" --yes 0.1.0
expect_failure "drafts in older versions" "Draft docs/release-notes/0.0.9/late.md" --yes 0.1.0
expect_failure "nested drafts in a finalized version" "Draft docs/upgrading/0.1.0/nested/step.md" --yes 0.1.0
expect_failure ".markdown drafts in a finalized version" "Draft docs/upgrading/0.1.0/missed.markdown" --yes 0.1.0
expect_failure "TBD in a finalized version" "Replace the TBD contents of docs/release-notes/0.1.0.md" --yes 0.1.0
has_tag 0.1.0 && fail "unconsolidated release notes: no tag is left behind"

git -C "$work" rm -qr docs/upgrading/0.1.0 docs/release-notes/0.0.9/late.md
printf '# Release notes 0.1.0\n\n#### The consolidated notes\n' > "$work/docs/release-notes/0.1.0.md"
open_notes 0.1.10
git -C "$work" add docs
add_commit "consolidated release notes"
if run_make --yes 0.1.0; then
    pass "drafts for later versions can remain"
else
    fail "drafts for later versions can remain"; sed 's/^/       /' "$err"
fi

new_world
mkdir -p "$work/docs/"{release-notes,upgrading}/0.2.0 "$work/modules/versioning/0.1.0"
cat > "$work/docs/release-notes/0.2.0/change.md" <<'EOF'
#### Release entry

See the
[second wallet migration][wallet].

```sh
wallet-check --offline
wallet-check --verify
```

[wallet]: ../../upgrading/0.2.0/second.md
EOF
for draft in first second; do
    printf '#### Migrate *wallets*\n\nBack up the wallet.\n' > "$work/docs/upgrading/0.2.0/$draft.md"
done
printf '\nVerify the backup before restarting.\n' >> "$work/docs/upgrading/0.2.0/second.md"
echo '#### Another migration' > "$work/docs/upgrading/0.2.0/third.md"
echo '#### Withdrawn during development' > "$work/docs/upgrading/0.2.0/withdrawn.md"
echo 'old notice' > "$work/modules/versioning/0.1.0/old.nix"
git -C "$work" add docs
expect_rejection "the first draft needs both milestone pages" 'Missing version page docs/release-notes/0.2.0.md' run_notes 0.1.0 HEAD
open_notes 0.2.0
git -C "$work" add docs
draftDir=docs/upgrading/0.2.0
cat > "$work/$draftDir/no-heading.md" <<'EOF'
```md
#### Only a code example
```
EOF
git -C "$work" add "$draftDir/no-heading.md"
expect_rejection "a draft needs a real heading in its own PR" 'no-heading.md: start the draft with a fourth-level heading' run_notes 0.1.0 HEAD
git -C "$work" rm -qf "$draftDir/no-heading.md"
mkdir -p "$work/$draftDir/nested"
for misplaced in nested/change.md change.markdown; do
    echo '#### A misplaced draft' > "$work/$draftDir/$misplaced"
    git -C "$work" add "$draftDir/$misplaced"
    expect_rejection "CI catches a misplaced draft at $misplaced" "$misplaced: put each draft directly in" run_notes 0.1.0 HEAD
    git -C "$work" rm -qf "$draftDir/$misplaced"
done
open_notes 0.2.0
if git -C "$work" diff --quiet -- docs; then
    pass "opening a milestone twice preserves the pages and navigation"
else
    fail "opening a milestone twice preserves the pages and navigation"
fi
for guide in upgrading release-notes; do
    for index in SUMMARY "$guide"; do
        sed -i "\\|]($guide/0.2.0.md)|d" "$work/docs/$index.md"
        expect_rejection "first drafts need the $guide entry in $index" "docs/$index.md: add a link to docs/$guide/0.2.0.md" run_notes 0.1.0 HEAD
        open_notes 0.2.0
    done
done
if python3 "$work/helper/open-release-notes.py" 0.1.0 >"$out" 2>"$err"; then
    fail "opening a finalized milestone is rejected"
else
    pass "opening a finalized milestone is rejected"
fi
for index in upgrading release-notes; do
    cat >> "$work/docs/$index.md" <<'EOF'
- [Draft directory](https://github.com/bitcoinix/bitcoinix/tree/master/docs/upgrading/0.2.0)
- [Upstream note](https://github.com/other/repo/blob/master/docs/upgrading/0.2.0/old.md)
- Markdown example `[Draft](upgrading/0.2.0/example.md)`
EOF
done
echo '[Wallet migration](docs/upgrading/0.2.0/second.md)' > "$work/README.md"
git -C "$work" add docs modules README.md
add_commit "add draft notes"
git -C "$work" rm -q docs/upgrading/0.2.0/withdrawn.md
add_commit "withdraw an unreleased change while the milestone is still open"
# Simulate a draft that the previous checker allowed onto master.
mkdir -p "$work/$draftDir/legacy"
printf '#### Legacy migration\n\nRetain this migration.\n' > "$work/$draftDir/legacy/change.markdown"
git -C "$work" add "$draftDir/legacy/change.markdown"
add_commit "legacy draft in a nested directory"
draftBase=$(git -C "$work" rev-parse HEAD)

echo '- [Draft](./upgrading/0.2.0/first.md#steps)' >> "$work/docs/SUMMARY.md"
printf '\n[Draft][entry]\n\n[entry]: <release-notes/0.2.0/change.md>\n' >> "$work/docs/release-notes.md"
echo '<a href="https://github.com/bitcoinix/bitcoinix/blob/master/docs/upgrading/0.2.0/first.md">Draft</a>' >> "$work/docs/upgrading.md"
for index in SUMMARY upgrading release-notes; do
    expect_rejection "$index rejects individual draft links" "docs/$index.md: link to the version page" run_notes 0.1.0 "$draftBase"
done
git -C "$work" restore docs/{SUMMARY,upgrading,release-notes}.md

git -C "$work" switch -qc prepare
git -C "$work" rm -qr docs/{release-notes,upgrading}/0.2.0
cat > "$work/docs/upgrading/0.2.0.md" <<'EOF'
# Upgrading to config version 0.2.0

#### Another migration

#### Migrate wallets

Back up the wallet.

Verify the backup before restarting.

```md
#### Migrate wallets
```
EOF
echo '# Release notes 0.2.0' > "$work/docs/release-notes/0.2.0.md"
footer 0.2.0 >> "$work/docs/upgrading/0.2.0.md"
finish_indexes 0.2.0
echo '[Wallet migration](docs/upgrading/0.2.0.md#migrate-wallets-1)' > "$work/README.md"
# Existing notices can be renamed within their version. A notice added while
# finalizing 0.2.0 still belongs to the release being prepared.
git -C "$work" mv modules/versioning/0.1.0/{old,renamed}.nix
mkdir -p "$work/modules/versioning/0.2.0"
echo 'on-time notice' > "$work/modules/versioning/0.2.0/on-time.nix"
git -C "$work" add modules
git -C "$work" commit -qam "consolidate notes with missing headings"
beforeBump=$(git -C "$work" rev-parse HEAD)
expect_rejection "CI catches premature consolidation before the bump" 'keep the TBD page' run_notes 0.1.0 "$draftBase"
set_release_version 0.2.0
git -C "$work" commit -qam "bump the release version separately"
expect_rejection "CI catches entries dropped in a previous commit" 'missing the heading "Migrate wallets"' run_notes 0.2.0 "$beforeBump"
expect_rejection "tag mode catches entries dropped before the version bump" 'missing the heading "Migrate wallets"' run_notes 0.2.0
expect_rejection "a historical nested .markdown draft also needs consolidation" 'missing the heading "Legacy migration"' run_notes 0.2.0
git -C "$work" switch -q master
add_commit "concurrent change on master"
draftBase=$(git -C "$work" rev-parse HEAD)
git -C "$work" merge -q --no-ff -m "merge release preparation" prepare
push_to_origin master
expect_rejection "release PR checks each copy of a repeated heading" 'missing the heading "Migrate wallets"' run_notes 0.2.0 'HEAD^1'
expect_failure "signing checks the corresponding release page" 'release-notes/0.2.0.md is missing the heading "Release entry"' --yes 0.2.0

# The tag can be cut after a follow-up commit. The original drafts must still be checked.
echo '# Comment added after release preparation' >> "$work/version.nix"
add_commit "clarify release marker"
expect_failure "later commits preserve the consolidation check" 'missing the heading "Migrate wallets"' --yes 0.2.0
sed -i '/^After migrating/i #### Migrate wallets\n\nBack up the wallet.\n\n#### Legacy migration\n\nRetain this migration.\n' "$work/docs/upgrading/0.2.0.md"
cat >> "$work/docs/release-notes/0.2.0.md" <<'EOF'

#### Release entry

See the [second wallet migration](../upgrading/0.2.0.md#migrate-wallets-1).

```sh
wallet-check --offline
wallet-check --verify
```
EOF
add_commit "restore omitted entries"
releaseBase=$(git -C "$work" rev-parse HEAD)

# Exercise both public entry points with a clean, pushed tree for each case.
reject_notes_change() {
    add_commit "$1"
    expect_rejection "CI: $1" "$2" run_notes 0.2.0 "$releaseBase"
    expect_failure "signing: $1" "$2" --yes 0.2.0
    has_tag 0.2.0 && fail "$1 left a tag"
    git -C "$work" restore --source="$releaseBase" --staged --worktree -- docs README.md
}

for guide in upgrading release-notes; do
    page="$work/docs/$guide/0.2.0.md"
    sed -i '1d' "$page"
    reject_notes_change "missing $guide title" 'start the page with'
    sed -i "\\|]($guide/0.2.0.md)|s/$/ (upcoming)/" "$work/docs/$guide.md"
    reject_notes_change "$guide still marked upcoming" 'remove the \(upcoming\) label'
done
rm "$work/docs/upgrading/0.2.0.md"
reject_notes_change "missing finalized upgrade page" 'Missing version page docs/upgrading/0.2.0.md'
page="$work/docs/upgrading/0.2.0.md"
sed -i '/^After migrating/d' "$page"
reject_notes_change "missing final configVersion instruction" 'end with an instruction to set'
sed -i 's/configVersion = "0.2.0"/configVersion = "0.1.0"/' "$page"
reject_notes_change "wrong final configVersion" 'end with an instruction to set'
sed -i '/^After migrating/i While in development, keep bitcoinix.configVersion = "0.1.0";\n' "$page"
reject_notes_change "development instruction alongside the correct footer" 'remove the development instruction'
sed -i -e '/^Verify the backup before restarting\./d' \
    -e '/^#### Another migration/a Verify the backup before restarting.' "$page"
reject_notes_change "a migration step moved under an unrelated heading" 'missing draft text under "Migrate wallets".*Verify the backup'
page="$work/docs/release-notes/0.2.0.md"
sed -i '/^#### Release entry/,$d' "$page"
printf '#### Release entry\n' >> "$page"
reject_notes_change "a heading survives but its entry text is gone" 'missing draft text under "Release entry"'
sed -i '/^wallet-check --verify$/d' "$page"
reject_notes_change "a command is missing from an otherwise complete entry" 'missing draft text.*wallet-check --verify'
echo '[Wallet migration](docs/upgrading/0.2.0/second.md)' > "$work/README.md"
reject_notes_change "README still links to a deleted draft" 'README.md: replace the link to the finalized draft'
echo '[Migration](../../upgrading/0.2.0/first.md)' >> "$page"
reject_notes_change "unconverted draft link" 'replace the link to the individual draft'
echo '[Migration](../../upgrading/0.2.0.md)' >> "$page"
reject_notes_change "relative link still starts in the draft directory" 'broken link.*missing target'
echo '[Migration](../upgrading/0.2.0.md#migrate-wallets-2)' >> "$page"
reject_notes_change "link to a missing rendered heading" 'broken link.*missing anchor'
echo '[Migration](upgrading/0.2.0.md#old-migration)' >> "$work/docs/release-notes.md"
reject_notes_change "link into a missing heading from another chapter" 'broken link.*missing anchor'

# A late PR can move its Markdown to the next milestone yet leave the notice behind.
for guide in upgrading release-notes; do
    mkdir -p "$work/docs/$guide/0.2.1"
    echo '#### Late entry' > "$work/docs/$guide/0.2.1/late.md"
done
open_notes 0.2.1
echo 'late notice' > "$work/modules/versioning/0.2.0/late.nix"
git -C "$work" add docs modules
add_commit "retarget only the Markdown"
expect_rejection "late PR checks new migration notices against its base" "New migration notice modules/versioning/0.2.0/late.nix" run_notes 0.2.0 "$releaseBase"
expect_failure "tagging detects a late notice after finalization" "New migration notice modules/versioning/0.2.0/late.nix" --yes 0.2.0
mkdir -p "$work/modules/versioning/0.2.1"
git -C "$work" mv modules/versioning/{0.2.0,0.2.1}/late.nix
add_commit "retarget the Nix notice"
if run_notes 0.2.0 "$releaseBase" && run_notes 0.2.0 "$draftBase" && run_make --yes 0.2.0; then
    pass "complete reordered pages and properly retargeted notices pass CI and signing"
    push_to_origin v0.2.0
    sed -i 's/wallet-check --verify/wallet-check --verify-backup/' "$work/docs/release-notes/0.2.0.md"
    add_commit "correct a command in the published guide"
    if run_notes 0.2.0 'HEAD^1'; then
        pass "CI accepts errata after the release tag"
    else
        fail "CI accepts errata after the release tag"; sed 's/^/       /' "$err"
    fi
else
    fail "complete reordered pages and properly retargeted notices pass CI and signing"; sed 's/^/       /' "$err"
fi

for example in "${exampleFiles[@]}"; do
    new_world
    sed -i 's/configVersion = "0.1.0"/configVersion = "0.0.9"/' "$work/$example"
    add_commit "old configVersion in $example"
    expect_failure "$example: stale configVersion" "configVersion in $example to 0.1.0" --yes 0.1.0
    has_tag 0.1.0 && fail "$example: stale configVersion left a tag"

    new_world
    rm "$work/$example"
    add_commit "missing $example"
    expect_failure "$example: missing file" "Missing example: $example" --yes 0.1.0
    has_tag 0.1.0 && fail "$example: missing file left a tag"

    new_world
    sed -i '/configVersion = /d' "$work/$example"
    add_commit "missing configVersion in $example"
    expect_failure "$example: missing configVersion" "configVersion in $example to 0.1.0" --yes 0.1.0
    has_tag 0.1.0 && fail "$example: missing configVersion left a tag"

    if [[ $example == */flake.nix ]]; then
        new_world
        sed -i 's|github:bitcoinix/bitcoinix/v0.1.0|github:bitcoinix/bitcoinix/v0.0.9|' "$work/$example"
        add_commit "old release pin in $example"
        expect_failure "$example: stale release pin" "release pin in $example to v0.1.0" --yes 0.1.0
        has_tag 0.1.0 && fail "$example: stale release pin left a tag"

        new_world
        sed -i -E '/(bitcoinix|nix-bitcoin)\.url = /d' "$work/$example"
        add_commit "missing release pin in $example"
        expect_failure "$example: missing release pin" "release pin in $example to v0.1.0" --yes 0.1.0
        has_tag 0.1.0 && fail "$example: missing release pin left a tag"
    fi
done

new_world
git config --file "$GIT_CONFIG_GLOBAL" --unset gpg.format
expect_failure "gpg.format unset" "gpg.format" --yes 0.1.0
git config --file "$GIT_CONFIG_GLOBAL" gpg.format ssh

new_world
git config --file "$GIT_CONFIG_GLOBAL" --unset user.signingkey
expect_failure "no signing key configured" "user.signingkey" --yes 0.1.0
git config --file "$GIT_CONFIG_GLOBAL" user.signingkey "$tmp/trusted.pub"

# Signed with a key that is not in the allowed signers file
new_world
git config --file "$GIT_CONFIG_GLOBAL" user.signingkey "$tmp/untrusted.pub"
expect_failure "signing key not in allowed signers" "verification of v0.1.0 failed" --yes 0.1.0
if has_tag 0.1.0; then
    fail "signing key not in allowed signers: the local tag is removed"
else
    pass "signing key not in allowed signers: the local tag is removed"
fi
git config --file "$GIT_CONFIG_GLOBAL" user.signingkey "$tmp/trusted.pub"

# Signed with a listed key that has been revoked
new_world
{ echo '# revoked'; cat "$tmp/trusted.pub"; } > "$revoked"
expect_failure "signing key revoked" "verification of v0.1.0 failed" --yes 0.1.0
if has_tag 0.1.0; then
    fail "signing key revoked: the local tag is removed"
else
    pass "signing key revoked: the local tag is removed"
fi
echo '# no revoked keys' > "$revoked"

new_world
expect_failure "no terminal and no --yes" "--yes" 0.1.0
has_tag 0.1.0 && fail "no terminal and no --yes: no tag is left behind"

echo
if [[ -e $unexpectedPush ]]; then
    fail "the script pushed to origin"
fi
if ((failures)); then
    echo "$failures test(s) failed"
    exit 1
fi
echo "All make-release tests passed"
