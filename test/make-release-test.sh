#!/usr/bin/env bash
# Offline tests for helper/make-release.sh.
#
# Uses throwaway ssh keys and a local bare repository as `origin`, so no network
# access and no maintainer key are needed. The origin rejects every push that the
# test does not make itself, which proves that the script never publishes.
# Run directly or via `nix shell nixpkgs#{git,openssh,gnutar}`.
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
    cp "$repoRoot/helper/make-release.sh" "$repoRoot/helper/fetch-release.sh" "$work/helper/"
    local example
    for example in "${exampleFiles[@]}"; do
        mkdir -p "$work/${example%/*}"
        cp "$repoRoot/$example" "$work/$example"
    done
    set_release_version 0.1.0
    echo content > "$work/file"
    git -C "$work" add -A
    git -C "$work" commit -q -m "initial commit"
    git -C "$work" remote add origin "$origin"
    push_to_origin master
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
    set_release_version "$1"
    add_commit "prepare $1"
    run_make --yes "$1" || { echo "setup release $1 failed"; cat "$err"; exit 1; }
    push_to_origin "v$1"
}

origin_refs() { git -C "$origin" for-each-ref; }

# run_make [args...] -> captures stdout in $out, stderr in $err
run_make() {
    out=$tmp/stdout; err=$tmp/stderr
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
    if run_make "${@:3}"; then
        fail "$1 (accepted)"
    elif grep -qiE -- "$2" "$err"; then
        pass "$1"
    else
        fail "$1 (rejected, but not for the expected reason)"
        sed 's/^/       /' "$err"
    fi
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
