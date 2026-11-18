#### Core Lightning in systemd-nspawn

On the unstable package/system base, Core Lightning in systemd-nspawn needs
memory-locking syscalls allowed to keep its signing keys out of swap. For a custom
NixOS/systemd-nspawn container, add this to the **host** configuration, replacing
`node` with the container name:

```nix
containers.node.extraFlags = [ "--system-call-filter=@memlock" ];
```

Without it, `lightning_hsmd` aborts during startup. The bitcoinix container examples
and test runner already set this flag. The normal memory-lock limit still applies;
no additional capability is needed.
