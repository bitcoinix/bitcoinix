{ lib, stdenvNoCC, fetchFromGitHub, makeWrapper, python3 }:

stdenvNoCC.mkDerivation {
  pname = "utxoracle";
  # Upstream has no releases. The version is from the header of UTXOracle.py.
  version = "9.1-unstable-2025-08-06";

  src = fetchFromGitHub {
    owner = "Unbesteveable";
    repo = "UTXOracle";
    rev = "b9a3d91d84e7286cbd5378716d89013b736594bc";
    hash = "sha256-qcWdFaQUvThmVb9foWVUo9RSy0oqBZvJe8p3bSMWUZk=";
  };

  nativeBuildInputs = [ makeWrapper ];

  # The script is installed unmodified. Its license allows adapting it to the
  # local environment, but not changing the price logic.
  installPhase = ''
    runHook preInstall
    install -Dm644 UTXOracle.py $out/libexec/utxoracle/UTXOracle.py
    install -Dm644 LICENSE $out/share/licenses/utxoracle/LICENSE
    makeWrapper ${python3.interpreter} $out/bin/utxoracle \
      --add-flags $out/libexec/utxoracle/UTXOracle.py
    runHook postInstall
  '';

  meta = with lib; {
    description = "Bitcoin price oracle that uses only confirmed on-chain data from your node";
    homepage = "https://utxo.live/oracle/";
    license = {
      shortName = "UTXOracle";
      fullName = "UTXOracle License 1.0";
      url = "https://github.com/Unbesteveable/UTXOracle/blob/main/LICENSE";
      free = false;
      redistributable = true;
    };
    mainProgram = "utxoracle";
    platforms = platforms.all;
  };
}
