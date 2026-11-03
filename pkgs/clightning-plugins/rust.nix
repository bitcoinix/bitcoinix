{ lib, rustPlatform, clightning, unzip, protobuf }:

let
  commonAttrs = {
    inherit (clightning) src;
    cargoHash = "sha256-iNW/aB3uZxAUvjhq5rIAFzj1tP/F1K/mjdvmTUfmz6s=";

    depsExtraArgs = {
      nativeBuildInputs = [ unzip ];
      # Vendor the Cargo workspace without running CLN's configure script.
      dontConfigure = true;
    };
    nativeBuildInputs = [ unzip ];
  };
in
{
  clnrest = rustPlatform.buildRustPackage (finalAttrs: commonAttrs // {
    pname = "clnrest";
    version = "0.2.0"; # plugins/rest-plugin/Cargo.toml

    cargoBuildFlags = [ "--package clnrest" ];

    nativeCheckInputs = [
      # Required by lightning/cln-grpc/build.rs
      protobuf
    ];

    # `core::lsps2::htlc::tests::polls_until_channel_ready` (in the `cln-lsps`
    # workspace member) is timing-dependent: it spawns a polling task, sleeps a
    # real 10 ms, then asserts the loop ran more than once. Under the parallel
    # test load in CI the spawned task gets starved and the assertion fails.
    # Skip this single upstream test; the remaining workspace tests still run.
    checkFlags = [ "--skip=polls_until_channel_ready" ];

    passthru.path = lib.getExe finalAttrs.finalPackage;

    meta = with lib; {
      description = "REST plugin for Core Lightning";
      homepage = "https://github.com/ElementsProject/lightning/tree/master/plugins/rest-plugin";
      license = licenses.mit;
      mainProgram = "clnrest";
    };
  });

  currencyrate = rustPlatform.buildRustPackage (finalAttrs: commonAttrs // {
    pname = "clightning-plugin-currencyrate";
    version = "0.1.0"; # plugins/currencyrate-plugin/Cargo.toml

    # Build and test only this plugin, not the other CLN workspace members.
    cargoBuildFlags = [ "--package" "cln-currencyrate" ];
    cargoTestFlags = [ "--package" "cln-currencyrate" ];

    passthru.path = lib.getExe finalAttrs.finalPackage;

    meta = {
      description = "Bitcoin currency conversion using multiple price sources";
      homepage = "https://github.com/ElementsProject/lightning/tree/master/plugins/currencyrate-plugin";
      license = lib.licenses.mit;
      platforms = lib.platforms.unix;
      mainProgram = "cln-currencyrate";
    };
  });
}
