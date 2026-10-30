# The repository installs as a pi package and starts: `pi install ./pkg` works offline,
# settings and `pi list` name it, and `pi -p` runs up to the missing model key without a
# load error. Unlike `pi --help` and `pi --list-models`, which report no load error, `pi -p`
# loads the extensions. The npm dependencies are the flake inputs, linked by their package
# names into `node_modules` as npm would place them. pi skips a manifest path that does not
# exist without a message, so every manifest path is checked in the tree pi loads, and a
# positive line from a node_modules extension proves that route.
{
  pkgs,
  self,
}: let
  # The inputs npm stands for, by their package names.
  links = map (i: let
    src = self.inputs.${i};
  in {
    name = (builtins.fromJSON (builtins.readFile "${src}/package.json")).name;
    inherit src;
  }) ["pi-question" "pi-session-name" "pi-claude-auth"];
  linkLines = toString (map (l: ''
      mkdir -p "pkg/node_modules/$(dirname ${l.name})"
      ln -s ${l.src} pkg/node_modules/${l.name}
    '')
    links);
in
  pkgs.runCommand "pi-install-smoke" {nativeBuildInputs = [pkgs.pi-coding-agent pkgs.jq pkgs.coreutils pkgs.gnugrep];} ''
    export HOME=$PWD/home PI_CODING_AGENT_DIR=$PWD/home/.pi/agent PI_OFFLINE=1
    mkdir -p "$PI_CODING_AGENT_DIR"
    cp -r ${self} pkg
    chmod -R u+w pkg
    ${linkLines}
    # pi skips a missing manifest path silently: every one must exist in the tree pi loads
    while IFS= read -r p; do
      [ -f "pkg/$p" ] || { echo "pi-install-smoke: manifest path $p is missing in the installed tree" >&2; exit 1; }
    done < <(jq -r '.pi.extensions[]' pkg/package.json)
    pi install ./pkg >install.log 2>&1 || { cat install.log >&2; exit 1; }
    # the relative spelling of the entry, as pi writes it
    jq -e '.packages == ["../../../pkg"]' "$PI_CODING_AGENT_DIR/settings.json" >/dev/null \
      || { echo "unexpected settings.json:" >&2; cat "$PI_CODING_AGENT_DIR/settings.json" >&2; exit 1; }
    pi list >list.out 2>&1
    grep -qF "$PWD/pkg" list.out || { cat list.out >&2; exit 1; }
    # `pi -p` loads the extensions; a healthy package ends at the missing key
    rc=0
    pi -p x --no-session </dev/null >run.out 2>run.err || rc=$?
    cat run.out run.err >run.all
    grep -qF 'No API key found' run.all || { echo "pi did not reach the model call:" >&2; cat run.all >&2; exit 1; }
    # `! grep` is exempt from errexit: use `if`
    if grep -qF 'Failed to load extension' run.all; then
      echo "pi failed to load an extension:" >&2; cat run.all >&2; exit 1
    fi
    [ "$rc" = 1 ] || { echo "pi -p exited $rc, expected 1" >&2; exit 1; }
    # the node_modules route loaded: claude-auth prints a line at start when no Claude credentials exist (always here)
    grep -qF 'pi-claude-auth: ' run.all || { echo "the node_modules route did not load:" >&2; cat run.all >&2; exit 1; }
    # the observed entry, list lines and run output, for the build log
    echo "settings.json packages: $(jq -c .packages "$PI_CODING_AGENT_DIR/settings.json")"
    echo "pi list:"; cat list.out
    echo "pi -p output:"; cat run.all
    touch $out
  ''
