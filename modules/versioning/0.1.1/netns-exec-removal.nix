{ config, ... }:

{
  condition = config.nix-bitcoin.netns-isolation.enable;
  message = ''
    The `netns-exec` wrapper has been removed. Its namespace allowlist had been empty
    since joinmarket was removed, so it rejected every namespace.
    To run a command in a service namespace, use `sudo ip netns exec nb-<service> <command>`.
    Remove `nix-bitcoin.netns-isolation.allowedUser` from your configuration if you set it.
    '';
}
