# Markdown reference of the options declared by the bitcoinix modules, for the
# option list in docs/options.md. See helper/docs/build.py.
{ pkgs
, nixosModule
# The commit of this source, for the links to the declarations.
# `null` (a dirty checkout) links to master.
, rev ? null
}:
let
  inherit (pkgs) lib;

  # The flake source, which contains the module files
  root = toString ../..;
  sourceUrl = "https://github.com/bitcoinix/bitcoinix/blob/${if rev == null then "master" else rev}/";

  eval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = null;
    modules = [
      nixosModule
      {
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
        system.stateVersion = lib.trivial.release;
      }
    ];
  };

  doc = pkgs.nixosOptionsDoc {
    inherit (eval) options;
    # Options without a description are listed with their type and default
    warningsAreErrors = false;
    # Keep only the options declared in this source, not the NixOS options
    transformOptions = opt: let
      declarations = lib.filter (lib.hasPrefix "${root}/") (map toString opt.declarations);
    in opt // {
      visible = opt.visible && declarations != [];
      declarations = map (path: let
        file = lib.removePrefix "${root}/" path;
      in { name = file; url = sourceUrl + file; }) declarations;
    };
  };
in
pkgs.runCommand "bitcoinix-options.md" {
  nativeBuildInputs = [ pkgs.nixos-render-docs ];
} ''
  nixos-render-docs options commonmark \
    --manpage-urls ${pkgs.path + "/doc/manpage-urls.json"} \
    --revision "" \
    --anchor-style legacy \
    --anchor-prefix opt- \
    ${doc.optionsJSON}/share/doc/nixos/options.json \
    "$out"

  # A store path would show a build detail instead of the value a user sees
  if grep -n /nix/store "$out"; then
    echo "error: the option reference contains a store path (missing defaultText?)" >&2
    exit 1
  fi
''
