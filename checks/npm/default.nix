# The npm dependencies of the extension checks. ./package.json and ./package-lock.json are
# pi-retry's own files, byte for byte: its devDependencies pin typescript, @types/node and pi's
# packages, which the type check (../typecheck) and the actor-subagents suite (../actor-subagents,
# whose upstream modules import pi-tui at run time) use. The pname and the source set are kept as
# they are, so every flake that carries the same two files shares this derivation.
{
  lib,
  pkgs,
}: rec {
  nodeModules = pkgs.buildNpmPackage {
    pname = "pi-retry-test-deps";
    version = "0";
    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [./package.json ./package-lock.json];
    };
    npmDepsHash = "sha256-S8lO6fS9S3hRNlUdv7hztyfECeHBzeNArqaDjDQYqBE=";
    npmDepsFetcherVersion = 2;
    dontNpmBuild = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r node_modules $out/node_modules
      runHook postInstall
    '';
  };

  # The type check's toolchain is what the lock declares.
  check = let
    declared = (lib.importJSON ./package.json).devDependencies;
    pinned = ["typescript" "@types/node" "@earendil-works/pi-coding-agent"];
  in
    pkgs.runCommand "npm-deps" {nativeBuildInputs = [pkgs.jq];} ''
      set -euo pipefail
      ${lib.concatMapStrings (name: ''
          got=$(jq -r .version ${nodeModules}/node_modules/${name}/package.json)
          if [ "$got" != ${lib.escapeShellArg declared.${name}} ]; then
            echo "FAIL ${name}: installed $got, package.json declares ${declared.${name}}" >&2
            exit 1
          fi
          echo "ok ${name} $got"
        '')
        pinned}
      touch $out
    '';
}
