containerBin=$(type -P extra-container) || true
if [[ ! ($containerBin && $(realpath "$containerBin") == *extra-container-1.0.1*) ]]; then
    echo
    echo "Building extra-container. Skip this step by adding extra-container 1.0.1 to PATH."
    # Don't create an out-link: this script is often run as root, and a fixed
    # link name in a shared directory like /tmp can be pre-created by another user.
    # The store path in PATH keeps the package alive against the garbage collector
    # as long as the processes started from this shell run.
    containerPkg=$(nix build --no-link --print-out-paths "${BASH_SOURCE[0]%/*}"/../..#extra-container) || return
    if [[ ! -x $containerPkg/bin/extra-container ]]; then
        echo "Error: Building extra-container failed: '$containerPkg/bin/extra-container' not found." >&2
        return 1
    fi
    export PATH="$containerPkg/bin${PATH:+:}$PATH"
    unset containerPkg
fi
