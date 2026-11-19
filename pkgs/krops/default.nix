{ pkgs ? import <nixpkgs> {} }:

let
  version = "1.31.1";
  src = pkgs.fetchgit {
    url = "https://cgit.krebsco.de/krops";
    tag = "v${version}";
    hash = "sha256-qYCxvdJ9RHz+Sh2HLv6zVU10J3UT85FgpEQJEjJFXbU=";
  };

  # TODO-EXTERNAL:
  # Remove when upstream keeps the ssh control socket path within the
  # 104-108 bytes of a Unix socket path.
  # populate creates its control socket at
  # `$TMPDIR/populate.XXXXXXXX/ssh-%r@%h:%p.sock`, which is too long with the
  # default TMPDIR on macOS, within nix-shell on CI, or for an onion host, and
  # ssh then fails. The patch moves only the socket to a private /tmp
  # directory and names it by the hashed `%C`. Sources keep using TMPDIR,
  # where `pass` and `passage` decrypt secrets.
  patchedSrc = pkgs.applyPatches {
    name = "krops-${version}-patched";
    inherit src;
    patches = [ ./populate-control-socket.patch ];
  };
in {
  inherit version src;
  lib = import "${src}/lib";
  pkgs = rec {
    krops = let
      krops = pkgs.callPackage "${src}/pkgs/krops" { inherit populate; };
    in krops // {
      # TODO-EXTERNAL:
      # Remove when upstream's `useNixOutputMonitor` keeps the exit status of
      # nixos-rebuild.
      # By default, writeDeploy pipes nixos-rebuild through nom if nom is
      # installed on the node. The deployment then exits with nom's status,
      # which is 0 after a failed evaluation or activation.
      writeDeploy = name: args:
        krops.writeDeploy name ({ useNixOutputMonitor = false; } // args);
    };
    populate = pkgs.callPackage "${patchedSrc}/pkgs/populate" {};
  };
}
