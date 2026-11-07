{ lib
, rustPlatform
, fetchFromGitHub
}:

# Upstream: https://github.com/NixOS/nixpkgs/pull/584673 (rbitcoin: init at 0.9.0).
# Once it lands in the pinned nixpkgs, drop this file and take rbitcoin from
# nixpkgs in pkgs/default.nix.
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "rbitcoin";
  # 0.9.0 is the first tag with the scripthash reorg fix (rbitcoin#1021).
  # SCHEMA_VERSION is still 26, so a data directory from the earlier
  # unstable pin opens unchanged.
  version = "0.9.0";

  src = fetchFromGitHub {
    owner = "rbitcoin-org";
    repo = "rbitcoin";
    rev = "v${finalAttrs.version}";
    hash = "sha256-xLvGL1W6DQatGvYOQzHyHLSms1iuNFWiQRRr5byfpUQ=";
  };

  cargoHash = "sha256-MCt5EJ1MYOD3JrfMpqXxw60d7Q1Ny2IPX3ZctgEPqPk=";

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
