{ lib
, rustPlatform
, stdenvNoCC
, fetchFromGitHub
, bun
, nodejs
, makeWrapper
, pkg-config
, sqlite
, writableTmpDirAsHomeHook
}:
let
  version = "0.2.0";

  src = fetchFromGitHub {
    owner = "smolcars";
    repo = "rbitcoin-space";
    tag = "v${version}";
    hash = "sha256-8hANYKK9eXkJK5m58xWeyaqzZcNpoa6U/EaklaXwx38=";
  };

  # The frontend is built separately from the server, as upstream's Dockerfile does.
  # It imports its tokens, logo and font from design/, beside web/.
  web = stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "rbitcoin-space-web";
    inherit version src;

    nodeModules = stdenvNoCC.mkDerivation {
      pname = "rbitcoin-space-web-node-modules";
      inherit version src;
      sourceRoot = "${src.name}/web";

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
      # Depends on the bun version too: a bun update in nixpkgs can change
      # this hash
      outputHash = "sha256-/pubBcFTberuH+f6QTkxfYg/06VastNDk5bLb82vXzQ=";
    };

    nativeBuildInputs = [ bun nodejs ];

    buildPhase = ''
      runHook preBuild
      cd web
      cp -R ${finalAttrs.nodeModules} node_modules
      chmod -R u+w node_modules
      patchShebangs node_modules
      bun run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp -R dist $out
      runHook postInstall
    '';
  });
in
rustPlatform.buildRustPackage {
  pname = "rbitcoin-space";
  inherit version src;

  cargoHash = "sha256-88GsFebOBGXmSH+1wxmTLha0PTrv0UvhlWA3N1+Rt4o=";

  cargoBuildFlags = [ "-p" "rbitcoin-space" ];

  # The commit of tag v${version}, reported at /healthz. The source archive has no .git,
  # and build.rs only accepts a full commit hash.
  SOURCE_REVISION = "c7eb73555e6944b65eee03d24ead23aeddb26033";

  # Upstream CI runs the suite on every merge; several tests need a regtest rbitcoin
  # node or a browser, so the package only builds the server.
  doCheck = false;

  # nixpkgs' cargo setup hook sets LIBSQLITE3_SYS_USE_PKG_CONFIG, so rusqlite links
  # nixpkgs' SQLite instead of the copy that upstream's `bundled` feature compiles in.
  nativeBuildInputs = [ makeWrapper pkg-config ];
  buildInputs = [ sqlite ];

  postInstall = ''
    mkdir -p $out/share/rbitcoin-space
    ln -s ${web} $out/share/rbitcoin-space/web
    wrapProgram $out/bin/rbitcoin-space \
      --set-default WEB_DIR $out/share/rbitcoin-space/web
  '';

  passthru = { inherit web; inherit (web) nodeModules; };

  meta = {
    description = "Block explorer for rbitcoin: live mempool, blocks, mining and Lightning";
    homepage = "https://github.com/smolcars/rbitcoin-space";
    license = lib.licenses.mit;
    mainProgram = "rbitcoin-space";
    platforms = lib.platforms.linux;
  };
}
