{ lib
, rustPlatform
, fetchFromGitHub
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "rbitcoin";
  # Unreleased master: v0.8.0 predates the scripthash reorg fix
  # (reardencode/rbitcoin#1018, fixed in #1021), which on mainnet stalls the
  # node for hours and leaks hundreds of GB on any one-block reorg.
  # This rev runs a mainnet node (SCHEMA_VERSION 26). Move to the next tag
  # once it includes that fix.
  version = "0.8.99-unstable-2026-10-24";

  src = fetchFromGitHub {
    owner = "reardencode";
    repo = "rbitcoin";
    rev = "f76514151421db4c1b155871fd222783549f13dc";
    hash = "sha256-vxI/ulD7ghZ+6sysFbER1vaB1uU8wFSm3i9sklzFhl8=";
  };

  cargoHash = "sha256-em4GOljXerUFnbCisQhF39oNG0nTaOtrIu63VWPI3c8=";

  cargoBuildFlags = [ "-p" "rbitcoin-node" "-p" "rbitcoin-cli" ];

  # The upstream suite needs io_uring and runs for minutes; upstream CI runs it
  # on every merge, so the package only builds the two shipped binaries.
  doCheck = false;

  meta = {
    description = "Experimental Bitcoin full node in Rust with built-in Electrum and Esplora servers";
    homepage = "https://github.com/reardencode/rbitcoin";
    license = with lib.licenses; [ mit asl20 ];
    mainProgram = "rbitcoin-node";
    platforms = lib.platforms.linux;
  };
})
