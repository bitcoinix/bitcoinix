# vulnix for the CVE scan (test/ci/cve-scan.sh).
#
# nixpkgs ships vulnix 1.12.4, which reads `patches` only from the plain
# derivation environment. Packages built with `__structuredAttrs` keep it in the
# `__json` variable, so vulnix sees no patches there and reports every CVE that
# a CVE-named patch already fixes (all ten libssh2 CVEs in the first scan, see
# bitcoinix/bitcoinix#157). nix-community/vulnix@3596c69 (2026-10-19) fixes that
# and is in no release yet (1.12.5 is from 2026-07-31).
#
# This takes the nixpkgs package definition and swaps in the upstream source at
# a pinned commit. Drop this file and go back to `nixpkgs#vulnix` in cve-scan.sh
# once nixpkgs has a vulnix release with the fix.
#
# Built with:  nix build --impure -f test/ci/vulnix.nix
let
  f = builtins.getFlake (builtins.toString ./../..);
  pkgs = import f.inputs.nixpkgs { system = builtins.currentSystem; };
in
pkgs.vulnix.overrideAttrs (old: {
  version = "1.12.5-unstable-2026-10-26";
  src = pkgs.fetchFromGitHub {
    owner = "nix-community";
    repo = "vulnix";
    rev = "525eb2c306dc8ca1a6ff6d48d33dc2d515fc6493";
    hash = "sha256-PGskKb50N+J/R2GzXRbOfdd311Mywi/Tr/BIZ+bpyCA=";
  };
})
