{ config, ... }:

{
  condition = !config.programs.fuse.enable;
  message = ''
    Unstable NixOS disables programs.fuse.enable by default. If you use
    non-root FUSE mounts, such as an sshfs backup target, set
    programs.fuse.enable = true; to retain the privileged mount helper.
    Encrypted Core Lightning replication enables it automatically.
  '';
}
