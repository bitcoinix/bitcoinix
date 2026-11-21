qemuDir=$(cd "${BASH_SOURCE[0]%/*}" && pwd)

# shellcheck disable=SC1091
source "$qemuDir/wait-until.sh"

# A private directory: a fixed path under /tmp lets another local user
# pre-create it and swap the VM link or disk image before they are used.
tmpDir=$(mktemp -d /tmp/nix-bitcoin-qemu-vm.XXXXXX)

# Cleanup on exit
cleanup() {
    set +eu
    if [[ $qemuPID ]]; then
        # The VM script runs QEMU and virtiofsd as child processes.
        # Kill the VM's whole process group.
        kill -9 -- "-$qemuPID"
    fi
    rm -rf "$tmpDir"
}
trap "cleanup" EXIT

identityFile=$qemuDir/id-vm
chmod 0600 "$identityFile"

runVM() {
    vm=$1
    sshPort=$2

    export NIX_DISK_IMAGE="$tmpDir/img"
    # Bind the SSH forward to loopback only. The demo VM authorizes the
    # committed key `id-vm` for root, so a wildcard bind would let every host
    # on the network log in as root while the VM runs.
    export QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:${sshPort}-:22"
    # QEMU can't start when the port is in use, e.g. by a VM left running.
    # The SSH commands would then reach that other VM.
    if (exec 3<>"/dev/tcp/127.0.0.1/$sshPort") 2>/dev/null; then
        >&2 echo "error: port $sshPort is already in use"
        exit 1
    fi
    # Start the VM in its own process group, so that cleanup() stops all of
    # its processes
    set -m
    # shellcheck disable=SC2211
    </dev/null "$vm"/bin/run-*-vm &>/dev/null &
    qemuPID=$!
    set +m
}

vmIsRunning() {
    if ! kill -0 "$qemuPID" 2>/dev/null; then
        echo
        >&2 echo "error: the VM has stopped"
        exit 1
    fi
}

vmWaitForSSH() {
    echo
    printf "Waiting for SSH connection..."
    waitUntil "vmIsRunning && c : 2>/dev/null" 500
    echo
}

# Run command in VM
c() {
    ssh -p "$sshPort" -i "$identityFile" -o IdentitiesOnly=yes -o ConnectTimeout=1 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ControlMaster=auto -o ControlPath="$tmpDir/ssh-connection" -o ControlPersist=60 \
        root@127.0.0.1 "$@"
}
export identityFile
export sshPort
export tmpDir
export -f c
