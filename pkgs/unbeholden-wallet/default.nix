{ lib
, stdenvNoCC
, fetchFromGitHub
, bun
, nodejs
, makeWrapper
, writableTmpDirAsHomeHook
}:
stdenvNoCC.mkDerivation rec {
  pname = "unbeholden-wallet";
  version = "0.3.0";

  src = fetchFromGitHub {
    owner = "unbeholdendev";
    repo = "unbeholden-wallet";
    tag = "v${version}";
    hash = "sha256-2qAGJxjqs0641OjA3CzNXERNON0G7t/5uA50MizCpYQ=";
  };

  nodeModules = stdenvNoCC.mkDerivation {
    pname = "${pname}-node-modules";
    inherit version src;

    nativeBuildInputs = [ bun writableTmpDirAsHomeHook ];
    impureEnvVars = lib.fetchers.proxyImpureEnvVars;

    dontConfigure = true;
    # `--cpu` and `--os` fetch the native packages of every platform, so the hash
    # is the same on x86_64-linux and aarch64-linux.
    buildPhase = ''
      bun install --cpu='*' --os='*' --frozen-lockfile --ignore-scripts --no-progress
    '';
    installPhase = ''
      cp -R node_modules $out
    '';
    # Fixup would add store references, which a fixed-output derivation must not have
    dontFixup = true;

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-idJSmsFrlKoMX000iGH7zKn39Z1oaa+jy/3tFA74TcM=";
  };

  nativeBuildInputs = [ bun nodejs makeWrapper ];

  APP_VERSION = "v${version}";

  buildPhase = ''
    runHook preBuild
    cp -R ${nodeModules} node_modules
    chmod -R u+w node_modules
    patchShebangs node_modules
    bun run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share $out/lib/unbeholden-wallet
    cp -R dist $out/share/unbeholden-wallet
    cp container/serve.ts $out/lib/unbeholden-wallet
    makeWrapper ${bun}/bin/bun $out/bin/unbeholden-wallet \
      --add-flags $out/lib/unbeholden-wallet/serve.ts \
      --set-default ROOT $out/share/unbeholden-wallet
    runHook postInstall
  '';

  passthru = { inherit nodeModules; };

  meta = with lib; {
    description = "Watch-only Bitcoin wallet in the browser that signs on an air-gapped device";
    homepage = "https://github.com/unbeholdendev/unbeholden-wallet";
    license = licenses.asl20;
    platforms = platforms.linux;
    mainProgram = "unbeholden-wallet";
  };
}
