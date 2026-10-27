{
  pkgs,
  system,
  self,
}:
let
  inherit (self.inputs.colmena.packages.${system}) colmena;

  inputs = with pkgs; [
    # To generate hashed user passwords
    mkpasswd

    colmena
    self.inputs.agenix.packages.${system}.agenix
  ];

  # pname/name may be absent on some derivations; skip those rather than
  # crashing with a missing-attribute error.
  inputNames = builtins.concatStringsSep "\n" (
    builtins.filter (s: s != "") (map (p: p.pname or p.name or "") inputs)
  );
in
pkgs.mkShell {
  buildInputs = inputs;

  shellHook = ''
    echo "----------------"
    echo "Available tools:"
    echo "----------------"
    echo "${inputNames}"
    echo "----------------"
    echo
  '';
}
