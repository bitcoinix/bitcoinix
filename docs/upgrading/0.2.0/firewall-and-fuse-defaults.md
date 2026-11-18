#### Firewall and FUSE defaults

The OS update also changes these NixOS defaults:

- `networking.firewall.checkReversePath` changes from `true` (strict) to `"loose"`.
  Loose checking accepts a source reachable through any interface, rather than
  requiring the return route to use the incoming interface. Set
  `networking.firewall.checkReversePath = true;` to retain strict checking, after
  checking compatibility with your routing and VPN configuration.
- `programs.fuse.enable` defaults to `false`. If you use non-root FUSE mounts,
  such as an sshfs backup target, set `programs.fuse.enable = true;` to keep the
  privileged mount helper. Encrypted Core Lightning replication enables it
  automatically; unrelated operator mounts need their own setting.
