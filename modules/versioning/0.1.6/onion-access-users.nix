{ config, lib, ... }:

with lib;
let
  missingOnionAccessUsers = let
    userNames = map (u: u.name) (filter (u: u.enable or true) (attrValues config.users.users));
  in filter (user: !(elem user userNames)) (attrNames config.nix-bitcoin.onionAddresses.access);
in
{
  # Before 0.1.6, access could name users provisioned outside `users.users`
  # (useradd, LDAP/NSS) or disabled there. Compare login names as
  # onion-addresses.nix does. Both onion access entries can fire, even for the
  # same user, and then both apply.
  condition = missingOnionAccessUsers != [];
  message = ''
    `nix-bitcoin.onionAddresses.access` now accepts only users that are defined
    and enabled in `users.users`. These users aren't:
    ${concatStringsSep ", " missingOnionAccessUsers}
    Before, the onion-addresses service looked the names up at runtime, and a name
    that didn't resolve made it publish no onion address for anyone. Now evaluation
    checks them instead.
    To keep a user's access, define and enable the account in `users.users`. For an
    account created with useradd, declare its current uid, group, home and shell,
    since NixOS applies its defaults otherwise. Or remove the user from
    `nix-bitcoin.onionAddresses.access`.
  '';
}
