{ lib
, buildGo126Module
, fetchFromGitHub
}:
buildGo126Module rec {
  pname = "unbeholden-lnurl";
  version = "0.4.0";

  src = fetchFromGitHub {
    owner = "unbeholdendev";
    repo = "unbeholden-lnurl";
    tag = "v${version}";
    hash = "sha256-kYQXhBUweOSuQbOgB2A8f+e1qI8gtp6E2C8LwJggFGE=";
  };

  vendorHash = "sha256-KpeTQidAXnCdpaMCRTIk5TubovDGqRhhtcW/RjBJr1Q=";

  subPackages = [ "cmd/unbeholden-lnurl" ];
  ldflags = [ "-s" "-w" "-X main.version=v${version}" ];

  checkPhase = ''
    runHook preCheck
    go test ./cmd/... ./internal/...
    runHook postCheck
  '';

  meta = with lib; {
    description = "Self-hosted Lightning Address server for LND and Core Lightning";
    homepage = "https://github.com/unbeholdendev/unbeholden-lnurl";
    license = licenses.mit;
    mainProgram = "unbeholden-lnurl";
  };
}
