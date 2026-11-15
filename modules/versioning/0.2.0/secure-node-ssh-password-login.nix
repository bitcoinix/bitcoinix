{ config, ... }:

{
  # A config can define these options in ways that are hard to tell apart at
  # evaluation time, and a missed notice can lock the operator out of the node.
  # So notify every config with the preset and sshd.
  condition = config.nix-bitcoin ? secure-node-preset-enabled && config.services.openssh.enable;
  message = ''
    The secure-node preset now sets `services.openssh.settings.PasswordAuthentication`
    and `services.openssh.settings.KbdInteractiveAuthentication` to `false` by
    default, so sshd accepts only keys. This applies over the onion service and
    over the node's IP address. Before, the sshd onion service let anyone try
    passwords over Tor. If your config already sets both options to `false`,
    nothing changes. Otherwise, before deploying, check that each account that
    logs in over SSH has a key in `users.users.<name>.openssh.authorizedKeys.keys`.
    To keep password login, set `PasswordAuthentication = true`. If you log in with
    keyboard-interactive methods through PAM, for example one-time codes, check
    your PAM stack: NixOS sets `security.pam.services.sshd.unixAuth` from
    `PasswordAuthentication`, and some PAM modules depend on it. See
    docs/upgrading.md. Test a new login before you close your current session.
  '';
}
