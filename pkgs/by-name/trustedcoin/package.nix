{
  lib,
  buildGoModule,
  fetchFromGitHub,
  fetchpatch,
  nix-update-script,
}:

buildGoModule (finalAttrs: {
  pname = "trustedcoin";
  version = "0.8.7";

  __structuredAttrs = true;

  src = fetchFromGitHub {
    owner = "nbd-wtf";
    repo = "trustedcoin";
    tag = "v${finalAttrs.version}";
    hash = "sha256-mi+sri+N/EFXGm5JwNIAV+oXS0joOY5vef8FrKPmn7A=";
  };

  patches = [
    # Fix getchaininfo initialization races and reporting height 0 without a source.
    # https://github.com/nbd-wtf/trustedcoin/pull/44
    (fetchpatch {
      url = "https://github.com/nbd-wtf/trustedcoin/commit/3210fc9a5893cde597905dd3e6577d9791ae690d.patch";
      hash = "sha256-OPkZOf3t13Ti//WWfHII+KXSreXYYj2ogmRL0KZ5nvY=";
    })
    (fetchpatch {
      url = "https://github.com/nbd-wtf/trustedcoin/commit/21a1f43ffd558f79e145ae70f26f682eef19c1fe.patch";
      hash = "sha256-1Sr1WQYmCEmJpTq/YMxWx3EtE8xP+4fZKwgQUksc6CU=";
    })
  ];

  vendorHash = "sha256-fW+EoNPC0mH8C06Q6GXNwFdzE7oQT+qd+B7hGGml+hc=";

  # Not needed on any particular platform; trustedcoin has no cgo code. Matches
  # upstream's Makefile and gives a static binary without glibc in its closure.
  env.CGO_ENABLED = 0;

  # Drop the Go symbol table and DWARF info (~0.7 MB smaller), which the
  # default strip -S in fixupPhase leaves in place.
  ldflags = [
    "-s"
    "-w"
  ];

  # main_test.go spawns ./trustedcoin and speaks the plugin JSON-RPC over stdio
  preCheck = ''
    ln -s "$GOPATH/bin/trustedcoin" .
  '';

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Core Lightning plugin that replaces bitcoind with trusted public explorers";
    homepage = "https://github.com/nbd-wtf/trustedcoin";
    changelog = "https://github.com/nbd-wtf/trustedcoin/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [
      prusnak
      seberm
    ];
    mainProgram = "trustedcoin";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
