{ lib
, buildGo126Module
, fetchFromGitHub
}:
buildGo126Module rec {
  pname = "unbeholden-lnurl";
  version = "0.3.0";

  src = fetchFromGitHub {
    owner = "unbeholdendev";
    repo = "unbeholden-lnurl";
    rev = "0c36bd4630f49b7b3ac617c98e848f049d18f641";
    hash = "sha256-a64BMqBLtJLgranDnAR959rv61imvwM9bcEiP2SWCmY=";
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
    platforms = platforms.linux;
    mainProgram = "unbeholden-lnurl";
  };
}
