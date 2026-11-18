{ config, options, lib, ... }:

# Every change that breaks functionality from the user's point of view needs an
# entry under ./versioning (see "Breaking changes" in ../AGENTS.md).
# Let V be the upcoming release.
# 1. Add ./versioning/<V>/<identifier>.nix, a function taking config, options and/or
#    lib and returning { condition = ...; message = ...; }. The directory sets the version.
#    Starting at 0.1.0, refer to the version's upgrade page when it exists.
# 2. Keep ../version.nix and the example configVersion at the last release during
#    development. Advance both only in the release-preparation commit before
#    tagging (see ../dev/README.md).

with lib;
let
  versioningOptions = {
    nix-bitcoin.configVersion = mkOption {
      type = with types; nullOr str;
      default = null;
      example = "0.0.92";
      description = ''
        The released nix-bitcoin version whose configuration migrations you have completed.

        When upgrading to a backwards-incompatible release, nix-bitcoin will throw an
        error during evaluation and provide instructions for migrating your config to
        the new release.

        On master, unreleased migrations warn without blocking deployment or
        requiring acknowledgement. Review them before deploying; warnings cannot be
        acknowledged individually and repeat while applicable. Values newer than the
        latest finalized release are rejected. If unset, migration notices are disabled.
      '';
    };
    nix-bitcoin.versioning.releasedVersion = mkOption {
      internal = true;
      type = types.str;
      default = import ../version.nix;
      defaultText = literalExpression "import ../version.nix";
      description = "Latest finalized release; overridable for release-transition tests.";
    };
    # Lets tests check each notice
    nix-bitcoin.versioning.incompatibleChanges = mkOption {
      internal = true;
      readOnly = true;
      type = with types; listOf str;
      default = map (change: change.message) incompatibleChanges;
      defaultText = "(See source)";
      description = "Applicable migration messages, including unreleased warnings.";
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

        See ${if builtins.pathExists (../docs/upgrading + "/${version}.md")
          then "docs/upgrading/${version}.md"
          else "docs/upgrading.md"}.
      '';
  }) files) (sort lib.versionOlder (attrNames (filterAttrs (_: type:
    type == "directory"
  ) (builtins.readDir ./versioning))));

  version = config.nix-bitcoin.configVersion;

  releasedVersion = config.nix-bitcoin.versioning.releasedVersion;
  releasedChanges = optionals (version != null) (builtins.filter
    (change: versionAtLeast releasedVersion change.version
      && versionOlder version change.version
      && (change.condition or true)) changes);
  # Unreleased notices remain applicable regardless of configVersion.
  unreleasedChanges = optionals (version != null) (builtins.filter
    (change: versionOlder releasedVersion change.version
      && (change.condition or true)) changes);
  incompatibleChanges = releasedChanges ++ unreleasedChanges;

  errorMsg = ''

    This version of nix-bitcoin contains the following changes
    that are incompatible with your config (version ${version}):

    ${concatMapStringsSep "\n" (change: ''
      - ${change.message}(This change was introduced in version ${change.version})
    '') releasedChanges}
    After addressing the above changes, set nix-bitcoin.configVersion = "${releasedVersion}";
    in your nix-bitcoin configuration.
  '';

  warningMsg = ''
    This checkout contains unreleased configuration changes:

    ${concatMapStringsSep "\n" (change: ''
      - ${change.message}(Planned for version ${change.version})
    '') unreleasedChanges}
    These warnings do not block deployment or require acknowledgement.
    Review them before deploying. Keep nix-bitcoin.configVersion at
    ${releasedVersion} until the release is finalized; applicable warnings will repeat.
  '';
in
{
  imports = [
    ./obsolete-options.nix
  ];

  options = versioningOptions;

  config = {
    # Use the normal NixOS assertion path. A conditional definition of `system`
    # recurses when a migration checks users whose defaults depend on system.tools.
    warnings = optional (unreleasedChanges != []) warningMsg;
    assertions = [{
      assertion = version == null || versionAtLeast releasedVersion version;
      message = ''
        nix-bitcoin.configVersion = "${toString version}" is newer than the latest finalized release (${releasedVersion}).
        Set nix-bitcoin.configVersion = "${releasedVersion}" until the release is finalized.
      '';
    } {
      assertion = releasedChanges == [];
      message = errorMsg;
    }];
  };
}
