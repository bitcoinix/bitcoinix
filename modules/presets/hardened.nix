# This preset imported the NixOS hardened profile, which NixOS 26.05 removed
# together with the `linux_hardened` kernel. Since then, it had no effect.
# It is kept as a stub so that existing imports fail with an explanation
# instead of a missing-file error.
{
  assertions = [{
    assertion = false;
    message = ''
      The bitcoinix preset `modules/presets/hardened.nix` has been removed.
      It imported the NixOS hardened profile, which NixOS 26.05 removed together
      with the `linux_hardened` kernel. On NixOS 26.05 the preset had no effect.

      Remove the import from your configuration. For additional system hardening,
      consider `modules/presets/hardened-extended.nix` (see the comments at its
      top) or the NixOS Hardening wiki page:
      https://wiki.nixos.org/wiki/NixOS_Hardening
    '';
  }];
}
