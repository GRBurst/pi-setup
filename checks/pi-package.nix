# The pi package manifest (`package.json`) is one pi can install: private, marked with the
# gallery keyword, every resource path in the `pi` manifest exists once the npm dependencies
# are in place (the flake inputs stand in for npm: `node_modules/<name>` is the input whose
# package is named so), what pi itself provides is a peer (`*`) and never a dependency, and
# every one of those packages the repository's own TypeScript imports is a declared peer.
# `jq` and fixed-string `grep` at build time.
{
  pkgs,
  lib,
  self,
}: let
  # pi's packages documentation: provided by pi, so peers, never bundled.
  host = [
    "@earendil-works/pi-agent-core"
    "@earendil-works/pi-ai"
    "@earendil-works/pi-coding-agent"
    "@earendil-works/pi-tui"
    "typebox"
  ];
  # The inputs npm stands for, by their package names.
  sources = map (i: let
    src = self.inputs.${i};
  in {
    name = (builtins.fromJSON (builtins.readFile "${src}/package.json")).name;
    inherit src;
  }) ["pi-question" "pi-session-name" "pi-claude-auth"];
in
  pkgs.runCommand "pi-package-manifest" {nativeBuildInputs = [pkgs.jq pkgs.gnugrep pkgs.coreutils];} ''
    cp -r ${self} pkg
    chmod -R u+w pkg
    cd pkg
    fail=0
    bad() {
      echo "pi-package-manifest: $*" >&2
      fail=1
    }
    m=package.json
    [ -f "$m" ] || {
      echo "pi-package-manifest: no package.json" >&2
      exit 1
    }
    jq -e '.private == true' "$m" >/dev/null || bad "private is not true"
    jq -e '(.keywords // []) | index("pi-package") != null' "$m" >/dev/null || bad "the keyword pi-package is missing"
    jq -e '(.pi.extensions // []) | length > 0' "$m" >/dev/null || bad "the pi manifest lists no extension"

    ${lib.concatMapStrings (s: ''
        mkdir -p "$(dirname "node_modules/${s.name}")"
        ln -s ${s.src} "node_modules/${s.name}"
      '')
      sources}
    while IFS= read -r d; do
      [ -e "node_modules/$d" ] || bad "the dependency $d is none of this flake's inputs"
    done < <(jq -r '(.dependencies // {}) | keys[]' "$m")

    # a pi key that is not an array fails the check (not a silent skip of the later keys)
    if paths=$(jq -r '.pi | to_entries[] | .value | if type == "array" then .[] else error("a pi manifest key is not an array") end | select(type == "string")' "$m"); then
      while IFS= read -r p; do
        [ -e "$p" ] || bad "the manifest path $p does not exist"
      done <<<"$paths"
    else
      bad "the pi manifest cannot be read as paths (a key is not an array)"
    fi

    jq -e '(.peerDependencies // {}) | to_entries | all(.value == "*")' "$m" >/dev/null || bad "a peer dependency is not \"*\""
    for h in ${lib.escapeShellArgs host}; do
      if jq -e --arg h "$h" '(.dependencies // {}) | has($h)' "$m" >/dev/null; then
        bad "$h is a dependency; pi provides it (a peer)"
      fi
      if grep -rqF --include='*.ts' --exclude-dir=node_modules -e "\"$h\"" -e "'$h'" -e "\"$h/" -e "'$h/" .; then
        jq -e --arg h "$h" '(.peerDependencies // {}) | has($h)' "$m" >/dev/null || bad "$h is imported but not a peer dependency"
      fi
    done
    [ "$fail" = 0 ] || exit 1
    touch $out
  ''
