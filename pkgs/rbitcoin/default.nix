{ lib
, rustPlatform
, fetchFromGitHub
}:

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "rbitcoin";
  # Unreleased master: v0.8.0 predates the scripthash reorg fix
  # (reardencode/rbitcoin#1018, fixed in #1021), which on mainnet stalls the
  # node for hours and leaks hundreds of GB on any one-block reorg.
  # This rev has run a mainnet node since 2026-10-15. Move to the next tag
  # once it includes that fix.
  version = "0.8.0-unstable-2026-10-15";

  src = fetchFromGitHub {
    owner = "reardencode";
    repo = "rbitcoin";
    rev = "411db7a76bce86b23ced4ead7f38fe67549c4386";
    hash = "sha256-mPFtoEkA0SeRAeRbLSmAEITxsQqLyy94hYU88eyPhF8=";
  };

  cargoHash = "sha256-rH2kZlS2YT5QKsq/Abnzfo7qVotO95U2LGtBUul5gks=";

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
