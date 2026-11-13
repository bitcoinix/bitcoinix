pkgs: python3:
{
  nbPython3Packages = pkgs.python3Packages;

  # Re-enable `hwi`, which is unaffected by `CVE-2024-23342` because it doesn't
  # use python pkg `ecdsa` for signing. It no longer evaluates in nixpkgs after
  # `ecdsa` was tagged with this CVE.
  nbPython3PackagesWithUnlockedEcdsa = let
    python3PackagesWithUnlockedEcdsa = (python3.override {
      packageOverrides = self: super: {
        ecdsa = super.ecdsa.overrideAttrs (old: {
          meta = old.meta // {
            knownVulnerabilities = builtins.filter (x: x != "CVE-2024-23342") old.meta.knownVulnerabilities;
          };
        });
      };
    }).pkgs;
  in {
    hwi = with python3PackagesWithUnlockedEcdsa; toPythonApplication hwi;
  };
}
