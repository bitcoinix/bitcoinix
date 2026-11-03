pkgs: nbPython3Packages:

let
  inherit (pkgs) lib;

  src = pkgs.fetchFromGitHub {
    owner = "lightningd";
    repo = "plugins";
    rev = "f0d33fd32a35d207964f1f841ff80a744e6b8b09";
    hash = "sha256-ziQrTXksn2ZeH8q/eUlM+FJ9aj8fWjQ9aAHM5Jf/M3E=";
  };

  plugins = with nbPython3Packages; {
    feeadjuster = {
      version = "0.1.0"; # feeadjuster/pyproject.toml
      description = "Dynamically changes channel fees to keep your channels more balanced";
    };
    monitor = {
      version = "0.1.0"; # monitor/pyproject.toml
      description = "Helps you analyze the health of your peers and channels";
      extraPkgs = [ packaging ];
      # Upstream only uses packaging.version.parse, available in nixpkgs' 26.1.
      patchProject = ''
        substituteInPlace pyproject.toml --replace-fail 'packaging>=26.3' 'packaging>=${packaging.version}'
      '';
    };
    rebalance = {
      version = "0.1.0"; # rebalance/pyproject.toml
      description = "Keeps your channels balanced";
    };
    zmq = {
      version = "0.1.0"; # cl-zmq/pyproject.toml
      description = "Publishes notifications via ZeroMQ to configured endpoints";
      directory = "cl-zmq";
      scriptName = "cl-zmq";
      extraPkgs = [ twisted txzmq ];
    };
  };

  mkPlugin = name: plugin: let
    # packaging is also used to validate the runtime requirements below.
    python = pkgs.python3.withPackages (_:
      [ nbPython3Packages.pyln-client nbPython3Packages.packaging ] ++ (plugin.extraPkgs or []));
    script = "${plugin.scriptName or name}.py";
    drv = pkgs.stdenv.mkDerivation {
      pname = "clightning-plugin-${name}";
      version = "${plugin.version}-${builtins.substring 0 7 src.rev}";

      buildCommand = ''
        cp --no-preserve=mode -r '${src}/${plugin.directory or name}' "$out"
        cd "$out"
        ${plugin.patchProject or ""}

        # Validate pyproject.toml without invoking uv or downloading dependencies.
        ${python}/bin/python - <<'PY'
        import importlib.metadata
        import tomllib
        from packaging.requirements import Requirement
        with open("pyproject.toml", "rb") as f:
            project = tomllib.load(f)["project"]
        assert project["version"] == "${plugin.version}", project["version"]
        for dependency in project["dependencies"]:
            requirement = Requirement(dependency)
            if requirement.marker is None or requirement.marker.evaluate():
                version = importlib.metadata.version(requirement.name)
                assert version in requirement.specifier, f"{requirement}: installed {version}"
        PY

        # Upstream uses `uv run --script`; run with the closed Nix environment instead.
        substituteInPlace '${script}' \
          --replace-fail '#!/usr/bin/env -S uv run --script' '#!${python}/bin/python'
        chmod +x '${script}'
        LIGHTNINGD_PLUGIN=1 ${python}/bin/python - <<'PY'
        import json
        import subprocess
        request = {"jsonrpc": "2.0", "id": 1, "method": "getmanifest", "params": {}}
        result = subprocess.run(["./${script}"], input=json.dumps(request) + "\n\n",
                                text=True, capture_output=True, check=True, timeout=10)
        response = next(json.loads(line) for line in result.stdout.splitlines()
                        if line.strip() and json.loads(line).get("id") == 1)
        assert "result" in response, response
        PY
      '';

      passthru.path = "${drv}/${script}";

      meta = with lib; {
        inherit (plugin) description;
        homepage = "https://github.com/lightningd/plugins/tree/master/${plugin.directory or name}";
        license = licenses.bsd3;
        platforms = platforms.unix;
      };
    };
  in drv;

in
  builtins.mapAttrs mkPlugin plugins
