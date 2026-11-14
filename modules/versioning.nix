{ config, options, lib, ... }:

# Every change that breaks functionality from the user's point of view needs an
# entry under ./versioning (see "Breaking changes" in ../AGENTS.md).
# Let V be the upcoming release.
# 1. Add ./versioning/<V>/<identifier>.nix, a function taking config, options and/or
#    lib and returning { condition = ...; message = ...; }. The directory sets the version.
#    The collector appends a reference to the version's section in docs/upgrading.md
#    for versions 0.1.0 and newer.
# 2. Set `nix-bitcoin.configVersion = V` in ../examples/configuration.nix,
#    unless it already is.

with lib;
let
  versioningOptions = {
    nix-bitcoin.configVersion = mkOption {
      type = with types; nullOr str;
      default = null;
      example = "0.0.92";
      description = ''
        The nix-bitcoin release version that your config is compatible with.

        When upgrading to a backwards-incompatible release, nix-bitcoin will throw an
        error during evaluation and provide instructions for migrating your config to
        the new release.

        Once set, you only need to update this option when explicitly told to in an
        error message during evaluation.
      '';
    };
    # Lets tests check each notice
    nix-bitcoin.versioning.incompatibleChanges = mkOption {
      internal = true;
      readOnly = true;
      type = with types; listOf str;
      default = map (change: change.message) incompatibleChanges;
      defaultText = "(See source)";
      description = "Messages of the changes that apply to this config.";
    };
  };

  # Version directories sort numerically; notices within a version sort by filename.
  changes = concatMap (version: let
    dir = ./versioning + "/${version}";
    files = attrNames (filterAttrs (name: type:
      type == "regular" && hasSuffix ".nix" name
    ) (builtins.readDir dir));
  in map (name: let
    change = import (dir + "/${name}") { inherit config options lib; };
  in change // {
    inherit version;
    message = change.message
      + optionalString (versionAtLeast version "0.1.0") ''

        See docs/upgrading.md, "Upgrading to config version ${version}".
      '';
  }) files) (sort lib.versionOlder (attrNames (filterAttrs (_: type:
    type == "directory"
  ) (builtins.readDir ./versioning))));

  version = config.nix-bitcoin.configVersion;

  incompatibleChanges = optionals
    (version != null && versionOlder lastChange)
    (builtins.filter (change: versionOlder change && (change.condition or true)) changes);

  errorMsg = ''

    This version of nix-bitcoin contains the following changes
    that are incompatible with your config (version ${version}):

    ${concatMapStringsSep "\n" (change: ''
      - ${change.message}(This change was introduced in version ${change.version})
    '') incompatibleChanges}
    After addressing the above changes, set nix-bitcoin.configVersion = "${lastChange.version}";
    in your nix-bitcoin configuration.
  '';

  versionOlder = change: (builtins.compareVersions change.version version) > 0;
  lastChange = builtins.elemAt changes (builtins.length changes - 1);
in
{
  imports = [
    ./obsolete-options.nix
  ];

  options = versioningOptions;

  config = {
    # Force evaluation. An actual option value is never assigned
    system = optionalAttrs (builtins.length incompatibleChanges > 0) (builtins.throw errorMsg);
  };
}
