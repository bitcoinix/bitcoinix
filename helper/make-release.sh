#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash coreutils git gnugrep gnused gnutar openssh
set -euo pipefail

# Create and sign a bitcoinix release tag, then verify it exactly as users will.
# This script never pushes: publishing the tag is a deliberate manual step.
#
# Usage: helper/make-release.sh [-y|--yes] <version>
#
#   <version>  stable release version without the leading "v", e.g. 0.1.0
#   -y, --yes  do not ask for confirmation
#
# One-time setup, see "Cutting a release" in dev/README.md:
#   git config gpg.format ssh
#   git config user.signingkey <path to your public key>
# and your key must be listed in helper/release-keys/ssh-allowed-signers.
#
# Env vars (for forks and tests):
#   remote          git remote that holds the release branch and tags (default: origin)
#   branch          the only branch releases are cut from (default: master)
#   allowedSigners  path to the allowed signers file
#   revokedKeys     path to the revoked keys file
#
# The nix-shell dependencies cover helper/fetch-release.sh, which is run for the
# verification step.

scriptDir=$(cd "${BASH_SOURCE[0]%/*}" && pwd)

remote=${remote:-origin}
branch=${branch:-master}
allowedSigners=${allowedSigners:-$scriptDir/release-keys/ssh-allowed-signers}
revokedKeys=${revokedKeys:-$scriptDir/release-keys/ssh-revoked-keys}
# Do not inherit `version` from the environment, it is a positional argument here
version=
yes=

die() { >&2 printf 'Error: %s\n' "$@"; exit 1; }

usage() {
    >&2 echo "Usage: ${BASH_SOURCE[0]} [-y|--yes] <version>"
}

# `version` becomes part of a ref name and is passed on to fetch-release.sh
versionRegex='^[0-9]+\.[0-9]+\.[0-9]+$'

parse_args() {
    local arg
    for arg; do
        case $arg in
            -y|--yes) yes=1 ;;
            -h|--help) usage; exit 0 ;;
            -*) usage; die "Unknown option: '$arg'" ;;
            *)
                [[ -z $version ]] || { usage; die "More than one version given"; }
                version=$arg
                ;;
        esac
    done
    [[ $version ]] || { usage; die "Missing <version>"; }
    [[ $version =~ $versionRegex ]] ||
        die "Invalid version: '$version'. Expected stable X.Y.Z without a leading 'v'."
}

check_branch() {
    local current
    current=$(git symbolic-ref --short -q HEAD) ||
        die "HEAD is detached. Switch to '$branch'."
    [[ $current == "$branch" ]] ||
        die "On branch '$current'. Releases are cut from '$branch' only."
}

check_clean() {
    [[ -z $(git status --porcelain --untracked-files=no) ]] ||
        die "Tracked files have uncommitted changes."
}

# The tag must point at a commit that is already public, and nothing newer may exist
check_up_to_date() {
    git fetch -q -- "$remote" "refs/heads/$branch" ||
        die "Could not fetch '$branch' from '$remote'."
    [[ $(git rev-parse HEAD) == "$(git rev-parse FETCH_HEAD)" ]] ||
        die "HEAD is not at $remote/$branch. Run 'git pull --ff-only', or push your commits first."
}

check_tag_absent() {
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        die "Tag $tag already exists locally."
    fi
    # ls-remote --exit-code: 0 = match found, 2 = no match, anything else = error
    local status=0
    git ls-remote --exit-code --tags -- "$remote" "refs/tags/$tag" >/dev/null || status=$?
    case $status in
        2) ;;
        0) die "Tag $tag already exists on '$remote'." ;;
        *) die "Could not query tags of '$remote'." ;;
    esac
}

check_version_is_newest() {
    local highest
    highest=$(git ls-remote --tags --refs -- "$remote" 'refs/tags/v*' \
              | sed -nE 's|.*[[:space:]]refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$|\1|p' \
              | sort -V | tail -1) ||
        die "Could not list tags of '$remote'."
    [[ -z $highest ]] && return
    [[ $highest != "$version" &&
       $(printf '%s\n%s\n' "$highest" "$version" | sort -V | tail -1) == "$version" ]] ||
        die "Version $version is not greater than the latest release $highest."
}

check_migrations_finalized() {
    local releasedVersion example exampleVersion examplePin
    [[ -f version.nix ]] || die "Missing release marker: version.nix."
    releasedVersion=$(nix eval --raw --file version.nix)
    [[ $releasedVersion == "$version" ]] ||
        die "Set version.nix to $version in the release-preparation commit."
    for example in examples/configuration.nix examples/flakes/flake.nix \
        examples/colmena/flake.nix examples/container/flake.nix; do
        [[ -f $example ]] || die "Missing example: $example."
        exampleVersion=$(sed -nE 's/^[[:space:]]*(nix-bitcoin\.)?configVersion = "([^"]+)";$/\2/p' "$example")
        [[ $exampleVersion == "$version" ]] ||
            die "Set nix-bitcoin.configVersion in $example to $version in the release-preparation commit."
        if [[ $example == */flake.nix ]]; then
            examplePin=$(sed -nE 's#^[[:space:]]*(bitcoinix|nix-bitcoin)\.url = "github:[^/]+/[^/]+/v([^"]+)";$#\2#p' "$example")
            [[ $examplePin == "$version" ]] ||
                die "Set the bitcoinix release pin in $example to v$version in the release-preparation commit."
        fi
    done
}

check_signing_config() {
    [[ $(git config --get gpg.format || true) == ssh ]] ||
        die "git config gpg.format must be 'ssh'. Releases are SSH-signed."
    signingKey=$(git config --get user.signingkey || true)
    [[ $signingKey ]] ||
        die "git config user.signingkey is not set."
    [[ -f $allowedSigners ]] ||
        die "No allowed signers file at $allowedSigners"
    [[ -f $revokedKeys ]] ||
        die "No revoked keys file at $revokedKeys"
}

confirm() {
    [[ $yes ]] && return
    [[ -t 0 ]] || die "No terminal to ask for confirmation. Pass --yes to skip it."
    local reply
    read -r -p "Create and sign $tag? [y/N] " reply
    [[ $reply == [yY] ]] || die "Aborted."
}

# Run the same checks a user runs, against this repo and without pushing. This
# checks that the signer is listed, not revoked and inside its validity window, the tag is
# annotated and self-named, and that the SSH signature is good.
verify_tag() {
    if ! repoUrl="file://$PWD" releaseVersion=$version allowedSigners=$allowedSigners \
         revokedKeys=$revokedKeys \
         bash "$scriptDir/fetch-release.sh" >"$verifyOutput"; then
        # This script created the tag a moment ago, after checking that it was
        # absent locally and on the remote, and it was never pushed.
        git tag -d "$tag" >/dev/null
        die "Verification of $tag failed. The local tag was deleted."
    fi
}

parse_args "$@"
tag=v$version

# Make the paths absolute, since we change directory next
[[ $allowedSigners == /* ]] || allowedSigners=$PWD/$allowedSigners
[[ $revokedKeys == /* ]] || revokedKeys=$PWD/$revokedKeys

# The invoking user's git config is deliberately kept: the signing setup lives there
cd "$scriptDir/.."

signingKey=
verifyOutput=$(mktemp)
trap 'rm -f "$verifyOutput"' EXIT

check_branch
check_clean
check_up_to_date
check_tag_absent
check_version_is_newest
check_migrations_finalized
check_signing_config

commit=$(git rev-parse HEAD)
# Commit subjects are free text, so strip control characters before printing
subject=$(git log -1 --format=%s "$commit" | tr -d '[:cntrl:]')

printf 'Version:      %s\n' "$version"
printf 'Commit:       %s\n' "$commit"
printf 'Subject:      %s\n' "$subject"
printf 'Signing key:  %s\n' "$signingKey"
confirm

# --sign: the tag must be signed whatever tag.gpgsign says. An explicit commit
# makes sure the tag points at what was shown above. Hardware keys need a touch.
git tag --sign -m "bitcoinix $version" "$tag" "$commit" ||
    die "Could not create the signed tag $tag."

verify_tag

hash=$(sed -nE 's/^[[:space:]]*sha256 = "([^"]+)";$/\1/p' "$verifyOutput")

printf '\nCreated and verified signed tag %s at %s\n' "$tag" "$commit"
printf 'Tree hash (nix-hash --sri): %s\n' "$hash"
printf '\nNothing has been pushed. To publish the release:\n\n'
printf '  git push %q %q\n' "$remote" "$tag"
printf '\nTo undo before pushing:\n\n'
printf '  git tag -d %q\n' "$tag"
cat <<EOF

After pushing, check that:
  1. The "Verify release tags" workflow is green in GitHub Actions.
  2. From a clean clone, this verifies the signature, then downloads the archive into a
     throwaway Nix store and fails unless it is the signed tree:
       checkDownload=1 releaseVersion=$version helper/fetch-release.sh
     (For a fork, also set repoUrl=https://github.com/<owner>/<repo>.)
EOF
