{ lib
, rustPlatform
, fetchFromGitHub
}:

# Upstream: https://github.com/NixOS/nixpkgs/pull/584178 (rbitcoin: init).
# Once it lands in the pinned nixpkgs, drop this file and take rbitcoin from
# nixpkgs in pkgs/default.nix.
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "rbitcoin";
  # 0.9.2 refuses an IBD re-spend connect that earlier versions allowed.
  # Opening a 0.9.0 data directory rewrites store/meta to schema 27, one way:
  # 0.9.0 cannot open it afterwards. A store that already connected the bad
  # re-spend has to re-sync (see the upstream 0.9.2 release notes).
  version = "0.9.2";

  src = fetchFromGitHub {
    owner = "rbitcoin-org";
    repo = "rbitcoin";
    rev = "v${finalAttrs.version}";
    hash = "sha256-3pYDoPeu/ymprsZ7qm0bPJ3dN4YgmfxMpY77BFNVeRg=";
  };

  cargoHash = "sha256-0b2CnMuJ2iNgjPBhh3h74X4zn0rn+nWmuCnVpf43710=";

  cargoBuildFlags = [ "-p" "rbitcoin-node" "-p" "rbitcoin-cli" ];

  # The upstream suite needs io_uring and runs for minutes; upstream CI runs it
  # on every merge, so the package only builds the two shipped binaries.
  doCheck = false;

  meta = {
    description = "Experimental Bitcoin full node in Rust with built-in Electrum and Esplora servers";
    homepage = "https://github.com/rbitcoin-org/rbitcoin";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "rbitcoin-node";
    platforms = lib.platforms.linux;
  };
})
