# The type check of an extension's TypeScript: `tsc --noEmit --strict --allowImportingTsExtensions`
# over every .ts file of a package, with typescript, @types/node and pi's types from the npm lock
# (../npm). Four more flags, all for pi's own declarations: --skipLibCheck (pi-ai's .d.ts import
# JSON without import attributes and name an absent @modelcontextprotocol/sdk), --module nodenext
# and --target es2023 (the packages are "type": "module"), --types node.
{
  lib,
  pkgs,
  nodeModules,
}: rec {
  runner = pkgs.writeShellApplication {
    name = "pi-setup-tsc";
    runtimeInputs = [pkgs.nodejs pkgs.coreutils pkgs.findutils];
    text = ''
      src=''${1:?usage: pi-setup-tsc <package dir>}
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      cp -r "$src"/. "$work"/
      chmod -R u+w "$work"
      cd "$work"
      ln -sfn ${nodeModules}/node_modules node_modules
      mapfile -t files < <(find . -path ./node_modules -prune -o -name '*.ts' -print | LC_ALL=C sort)
      if [ "''${#files[@]}" -eq 0 ]; then
        echo "pi-setup-tsc: no .ts files under $src" >&2
        exit 2
      fi
      node node_modules/typescript/bin/tsc --noEmit --strict --allowImportingTsExtensions \
        --skipLibCheck --module nodenext --target es2023 --types node "''${files[@]}"
    '';
  };

  # One package: typecheck { name = "actor-subagents"; src = <a tree without tsconfig.json>; }
  typecheck = {
    name,
    src,
  }:
    pkgs.runCommand "typecheck-${name}" {} ''
      ${lib.getExe runner} ${src}
      touch $out
    '';

  # The runner accepts a clean package and rejects each kind of error it exists for.
  selftest = pkgs.runCommand "typecheck-harness" {nativeBuildInputs = [pkgs.gnugrep pkgs.nodejs];} ''
    set -euo pipefail
    tsc=${lib.getExe runner}
    fx=${./fixtures}
    want=${lib.escapeShellArg "Version ${(lib.importJSON ../npm/package.json).devDependencies.typescript}"}
    got=$(node ${nodeModules}/node_modules/typescript/bin/tsc --version)
    [ "$got" = "$want" ] || { echo "FAIL version: $got, want $want" >&2; exit 1; }
    echo "ok version $got"

    $tsc "$fx/ok" || { echo "FAIL ok: rejected" >&2; exit 1; }
    echo "ok ok"
    reject() {
      local out st=0
      out=$($tsc "$fx/$1" 2>&1) || st=$?
      [ "$st" -ne 0 ] || { echo "FAIL $1: accepted" >&2; exit 1; }
      grep -qF -- "$2" <<<"$out" || { echo "FAIL $1: rejected without '$2':" >&2; echo "$out" >&2; exit 1; }
      echo "ok $1 rejected with $2"
    }
    reject bad-strict 'error TS7006'
    reject bad-pi 'error TS2322'
    reject no-ts 'no .ts files'
    touch $out
  '';
}
