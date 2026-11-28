{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  makeWrapper,
  nodejs_24,
  nodejs-slim_24,
  tor,
}:

buildNpmPackage (finalAttrs: {
  pname = "cashu-orchard";
  version = "1.12.1";

  src = fetchFromGitHub {
    owner = "cashubtc";
    repo = "orchard";
    tag = "v${finalAttrs.version}";
    hash = "sha256-3J9ES25zmAe9huxqPtLUff2Xvor+RV51PaaQ2NXc2Ak=";
  };

  npmDepsHash = "sha256-lGkXLifA1yYH24AhrA/1QeN6pj818jSyUPXr7ZxXVmc=";
  nodejs = nodejs_24;

  patches = [ ./runtime-config.patch ./tor-proxy.patch ./network-privacy.patch ./ai-enabled.patch ];

  postPatch = ''
    substituteInPlace src/server/modules/api/public/network-guard.ts \
      --replace-fail '@torResolve@' '${tor}/bin/tor-resolve'
  '';

  postConfigure = ''
    # TODO-EXTERNAL: socks-proxy-agent 10.1.0 passes bracketed IPv6 hosts to net.connect.
    # Fix the shared dependency for both FetchService and the Telegram client.
    substituteInPlace node_modules/socks-proxy-agent/dist/index.js \
      --replace-fail 'const host = url.hostname;' 'const host = url.hostname.replace(/^\[|\]$/g, "");'
  '';

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ nodejs-slim_24 ];

  env = {
    CI = "true";
    NG_CLI_ANALYTICS = "false";
    npm_config_build_from_source = "true";
  };

  doCheck = true;
  checkPhase = ''
    runHook preCheck

    npm run test:server -- --runInBand

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    npm prune --omit=dev --ignore-scripts

    # Keep native addons without their build files and toolchain references.
    find node_modules/{bcrypt,better-sqlite3}/build \
      -type f ! -name '*.node' -delete
    rm -r node_modules/bcrypt/{node-addon-api,prebuilds}
    patchShebangs --host --update node_modules

    mkdir -p $out/lib/cashu-orchard/scripts
    cp -r dist node_modules package.json proto $out/lib/cashu-orchard
    cp scripts/generate-runtime-config.mjs $out/lib/cashu-orchard/scripts
    install -Dm644 LICENSE $out/share/licenses/cashu-orchard/LICENSE

    makeWrapper ${lib.getExe nodejs-slim_24} $out/bin/cashu-orchard \
      --chdir "$out/lib/cashu-orchard" \
      --set NODE_ENV production \
      --set npm_package_version ${finalAttrs.version} \
      --run "${lib.getExe nodejs-slim_24} $out/lib/cashu-orchard/scripts/generate-runtime-config.mjs" \
      --add-flags "$out/lib/cashu-orchard/dist/main.js"

    runHook postInstall
  '';

  disallowedRequisites = [
    nodejs_24
    nodejs-slim_24.src
    nodejs-slim_24.npm
    nodejs-slim_24.corepack
    nodejs-slim_24.python
    finalAttrs.npmDeps
  ];

  meta = {
    description = "Web application for Cashu mint management";
    homepage = "https://orchard.space";
    changelog = "https://github.com/cashubtc/orchard/releases/tag/${finalAttrs.src.tag}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ prusnak ];
    mainProgram = "cashu-orchard";
    platforms = lib.platforms.unix;
  };
})
