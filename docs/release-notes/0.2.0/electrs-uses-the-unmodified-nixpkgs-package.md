#### Electrs uses the unmodified nixpkgs package

Nixpkgs now supplies electrs' pkg-config and zstd build inputs, so the local
override is no longer needed.
