{ lib, options, ... }:

# Keeps configs that use the old `nix-bitcoin.*` option prefix working: the whole
# namespace is an alias of `bitcoinix.*`.
# `withPriority = false` keeps the priority of each definition, so `mkDefault` and
# `mkForce` under the old prefix still interact with definitions under the new one.
# Code that inspects option metadata (`options ? nix-bitcoin.foo`,
# `options.nix-bitcoin.foo.definitions`) must use `bitcoinix`, since
# `options.nix-bitcoin` is a single option.
{
  imports = [
    (lib.doRename {
      from = [ "nix-bitcoin" ];
      to = [ "bitcoinix" ];
      visible = false;
      warn = false;
      withPriority = false;
      use = lib.warn "`config.nix-bitcoin` is deprecated, read `config.bitcoinix` instead.";
    })
  ];

  config.warnings = lib.optional options.nix-bitcoin.isDefined ''
    The `nix-bitcoin.*` options were renamed to `bitcoinix.*`. Rename them in
    ${lib.showFiles options.nix-bitcoin.files}.
    The old prefix still works, but it will be removed in a later release.
  '';
}
