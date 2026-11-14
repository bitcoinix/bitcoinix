{ config, lib, ... }:

with lib;
{
  # Before 0.1.6, lnconnect-clnrest granted the operator clnrest onion access
  # even with the operator role disabled. Only configs that don't grant the
  # access themselves are affected. The operator account may come from outside
  # `users.users` (useradd, LDAP), so don't require it to be defined there.
  # The operator's lnd-rest access isn't checked here: lndconnect reads the
  # lnd user's copy, and the only reader of the operator's copy is nodeinfo,
  # which enables the operator role itself.
  condition = let
    operator = config.nix-bitcoin.operator;
    clnrest = config.services.clightning.plugins.clnrest;
    access = config.nix-bitcoin.onionAddresses.access.${operator.name} or [];
  in !operator.enable
     && clnrest.enable && clnrest.lnconnect.enable && clnrest.lnconnect.onion
     && !(elem "clnrest" access);
  message = let
    name = config.nix-bitcoin.operator.name;
    # The attribute that defines the account, which can differ from its name.
    # Prefer an enabled declaration, then a disabled one.
    accountKeys = filter (key: config.users.users.${key}.name == name)
      (attrNames config.users.users);
    account = findFirst (key: config.users.users.${key}.enable or true)
      (if accountKeys == [] then name else head accountKeys) accountKeys;
  in ''
    lnconnect-clnrest now gives the operator user access to the clnrest onion
    address only when `nix-bitcoin.operator.enable` is set. The operator role is
    disabled, so the operator user `${name}` doesn't get this access.
    To keep it, add "clnrest" to `nix-bitcoin.onionAddresses.access.${name}`,
    which needs `${name}` to be an enabled account in `users.users`. Or set
    `nix-bitcoin.operator.enable = true`, but only if the account is declared as
    an enabled `users.users.${name}` or doesn't exist yet, since the role
    declares it as a normal user. To run `lnconnect-clnrest` as
    `${name}` instead of root, also add "${config.services.clightning.group}" to
    `users.users.${account}.extraGroups`. That group can read the admin rune and use
    the clightning RPC socket.
  '';
}
