#### The secure-node preset turns off SSH password login

The `secure-node.nix` preset publishes sshd as an onion service. It now also sets
`services.openssh.settings.PasswordAuthentication` and
`services.openssh.settings.KbdInteractiveAuthentication` to `false` by default, so
sshd accepts only keys. Before, the NixOS defaults allowed passwords, and anyone who
knew the onion address could try the passwords of your accounts over Tor. This
includes the operator, whose groups control your node's funds. The change also
applies to SSH over the node's IP address, since it's the same sshd.

Evaluation reports this change for every configuration with the preset and
`services.openssh.enable`. If yours already sets both options to `false`, like the
flakes and Colmena examples, nothing changes.

Otherwise, before deploying, check that each account that logs in over SSH has its
key in `users.users.<name>.openssh.authorizedKeys.keys`. The preset gives the
operator the keys of root. Keep a root session or console access until a new login
with a key works.

To keep password login, set `services.openssh.settings.PasswordAuthentication = true;`.

If you log in with keyboard-interactive methods through PAM, for example one-time
codes, set `KbdInteractiveAuthentication = true` and check sshd's PAM stack. NixOS
sets `security.pam.services.sshd.unixAuth` from `PasswordAuthentication`, and PAM
modules differ in how they depend on it:

- With `googleAuthenticator`, NixOS adds the one-time code rule only when `unixAuth`
  or `services.homed.enable` is on. Without systemd-homed, set both options to `true`.
- With `otpwAuth`, `unixAuth` adds a password rule before the one-time password rule,
  so a plain password would be enough. Keep `PasswordAuthentication = false`.

For other modules, check the rules in `/etc/pam.d/sshd` after you build the system.
Either way, test a new login before you close your current session.

If your configuration sets one of these options to `true` with `lib.mkDefault`,
evaluation fails with "conflicting definition values", because the preset uses the
same priority. Then you don't see this notice. Set the option without `lib.mkDefault`
instead.
