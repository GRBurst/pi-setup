# The modules and the packages stay generic: they name none of the coupling points of a
# particular host configuration, and a module never reads the rendered files. Three rules:
#   (1) no file under `modules/` or `packages/` holds a forbidden token on a non-comment line
#       (fixed strings, case-sensitive): a host-side argument or option namespace (`osConfig`,
#       `programs.terminalKit`, `llm-agents`, `my.hm`, `my.nixos`, `config.my`) or a firewall
#       setting (`networking.firewall`); every `programs.<name>` names one of the namespaces
#       this repository may touch: its own (`pi`), the sandbox's (`aiSandbox`), the economics
#       bridge's (`piEconomics`) and Home Manager's own pi module (`pi-coding-agent`, which the
#       web module refuses to run beside); and no line reaches a namespace in a form that list
#       cannot check: any `programs` not followed by `.<ident>` (`programs ? x`, `programs."x"`,
#       `programs.${x}`, `programs.` followed by whitespace, a comment or the line end, `programs = {`, `inherit (config.programs) x`, `with config.programs;`,
#       an alias `progs = config.programs`, `["programs" ...]`);
#   (2) no non-comment line of a `.nix` file under `modules/` or `packages/` names a rendered
#       path (the `package.json` manifest, the `settings/` directory at the root: generated
#       from the modules, never read by them). A relative path must resolve inside the repository root
#       but not onto a rendered path, and must not be the root itself (a root path is how
#       `../.. + "/settings/x"` and `"${../..}/package.json"` reach one); a path that starts
#       with `/` must have no `..` segment (appended to a path, it climbs out of the module
#       directory); the strings `"/<file>`, `}/<file>`, `"/<dir>/`, `}/<dir>/`, `"/<dir>"`,
#       `}/<dir>"`, `"/..` and `}/..` are refused outright. This also covers code that no
#       evaluation reaches;
#   (3) the modules and the render evaluated from a copy of the repository without the
#       rendered paths, with every code path that reads a file of the repository switched on
#       (the web service, the static indicator, the local search; the render fixture F_P and the render tree): a
#       module or the render reading a rendered file, however it builds the path (`dirOf`,
#       string concatenation), fails the evaluation of this check with "No such file or
#       directory".
# Shell, not `builtins.match`: no regex over large text in Nix.
{
  pkgs,
  lib,
  home-manager,
  self,
}: let
  tokens = [
    "osConfig"
    "programs.terminalKit"
    "llm-agents"
    "my.hm"
    "my.nixos"
    "config.my"
    "networking.firewall"
  ];
  namespaces = ["pi" "aiSandbox" "piEconomics" "pi-coding-agent"];
  renderedFiles = ["package.json"];
  renderedDirs = ["settings"];
  rendered = renderedFiles ++ renderedDirs;
  # The strings that name one of them at the root (a directory name followed by more of the
  # name, as in pi's own `<agentDir>/settings.json`, is another path).
  named =
    lib.concatMap (f: ["\"/${f}" "}/${f}"]) renderedFiles
    ++ lib.concatMap (d: ["\"/${d}/" "}/${d}/" "\"/${d}\"" "}/${d}\""]) renderedDirs;

  # Rule (3): the source without the rendered paths; the module checks' fixtures over it.
  root = ../.;
  bare = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.difference root (lib.fileset.unions (map (d: lib.fileset.maybeMissing (root + "/${d}")) rendered));
  };
  bareFixtures = import "${bare}/checks/module/lib.nix" {
    inherit pkgs lib home-manager;
    inputs = self.inputs;
    piWeb = "${bare}/packages/pi-web";
  };
  bareHome = bareFixtures.piFixtureWith {
    programs.pi.web.enable = true;
    programs.pi.builtinExtensions.staticWorkingIndicator.enable = true;
    programs.pi.search.local.enable = true;
  };
  bareRender = import "${bare}/render" {
    inherit pkgs lib home-manager;
    inputs = self.inputs;
  };
  bareEvaluated =
    builtins.addErrorContext "boundary: while evaluating the modules and the render from a copy without ${toString rendered} (a module or the render reads a rendered file)"
    (builtins.unsafeDiscardStringContext (toString [
      bareHome.home.activationPackage.drvPath
      bareRender.fp.home.activationPackage.drvPath
      bareRender.tree.drvPath
    ]));
in
  pkgs.runCommand "boundary" {nativeBuildInputs = [pkgs.gnugrep pkgs.coreutils pkgs.findutils];} ''
    echo "boundary: the modules and the render evaluate without the rendered paths: ${bareEvaluated}"
    cd ${self}
    root=$(pwd)
    fail=0
    tokens=(${lib.concatMapStringsSep " " lib.escapeShellArg tokens})
    namespaces=(${lib.concatMapStringsSep " " lib.escapeShellArg namespaces})
    rendered=(${lib.concatMapStringsSep " " lib.escapeShellArg rendered})
    named=(${lib.concatMapStringsSep " " lib.escapeShellArg named})
    while IFS= read -r file; do
      for t in "''${tokens[@]}"; do
        while IFS= read -r hit; do
          echo "boundary: $file:''${hit%%:*}: token '$t'" >&2
          fail=1
        done < <(grep -n -v '^[[:space:]]*#' "$file" | grep -F -- "$t" || true)
      done
      while IFS= read -r numbered; do
        for ref in $(printf '%s\n' "''${numbered#*:}" | grep -oE 'programs\.[A-Za-z0-9_-]+'); do
          ns=''${ref#programs.}
          known=0
          for n in "''${namespaces[@]}"; do
            [ "$ns" = "$n" ] && known=1
          done
          if [ "$known" = 0 ]; then
            echo "boundary: $file:''${numbered%%:*}: option namespace '$ref' is none of: ''${namespaces[*]}" >&2
            fail=1
          fi
        done
      done < <(grep -n -v '^[[:space:]]*#' "$file" | grep -E 'programs\.[A-Za-z0-9_-]+' || true)
      # Any namespace read the dotted allow-list cannot see: a `programs` that is not `.<ident>`.
      while IFS= read -r hit; do
        echo "boundary: $file:''${hit%%:*}: an option namespace in a form the allow-list cannot check (write programs.<name>)" >&2
        fail=1
      done < <(grep -n -v '^[[:space:]]*#' "$file" | grep -E '(^|[^A-Za-z0-9_-])programs([^.A-Za-z0-9_-]|$)|programs[.]([^A-Za-z0-9_-]|$)' || true)
    done < <(find modules packages -type f | sort)
    while IFS= read -r file; do
      dir=$(dirname "$file")
      while IFS= read -r numbered; do
        n=''${numbered%%:*}
        text=''${numbered#*:}
        for s in "\"/.." "}/.."; do
          case $text in
            *"$s"*)
              echo "boundary: $file:$n: the string '$s' climbs out of a path" >&2
              fail=1
              ;;
          esac
        done
        for s in "''${named[@]}"; do
          case $text in
            *"$s"*)
              echo "boundary: $file:$n: the string '$s' names a rendered path" >&2
              fail=1
              ;;
          esac
        done
        for rel in $(printf '%s\n' "$text" | grep -oE '[A-Za-z0-9._/+-]*\.\.?/[A-Za-z0-9._/+-]*' || true); do
          case $rel in
            /*)
              case $rel/ in
                */../*)
                  echo "boundary: $file:$n: $rel starts with / and has a .. segment" >&2
                  fail=1
                  ;;
              esac
              continue
              ;;
          esac
          target=$(realpath -m "$dir/$rel")
          case $target in
            "$root")
              echo "boundary: $file:$n: $rel is the repository root" >&2
              fail=1
              ;;
            "$root"/*)
              for r in "''${rendered[@]}"; do
                case $target in
                  "$root/$r" | "$root/$r"/*)
                    echo "boundary: $file:$n: $rel is the rendered path $r" >&2
                    fail=1
                    ;;
                esac
              done
              ;;
            *)
              echo "boundary: $file:$n: $rel is outside the repository" >&2
              fail=1
              ;;
          esac
        done
      done < <(grep -n -v '^[[:space:]]*#' "$file" || true)
    done < <(find modules packages -type f -name '*.nix' | sort)
    [ "$fail" = 0 ] || exit 1
    touch $out
  ''
