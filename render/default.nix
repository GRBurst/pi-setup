# The render fixture and the render derivation.
#
# The files a user without Nix gets (`package.json`, the pi package manifest, and
# `settings/seed.json`) are the output of this repository's own module evaluated for one fixed
# configuration, F_P, and of `flake.lock`; only `nix run .#render` writes them into the
# checkout and the `render-*` checks compare them with `tree`. Every path here is relative, so
# `boundary` can evaluate the render from a copy of the repository without the rendered files.
{
  pkgs,
  lib,
  home-manager,
  # The flake's inputs: pi-question, pi-session-name, pi-claude-auth and ai-sandbox.
  inputs,
}: let
  stub = name: pkgs.writeShellScriptBin name "exit 0";

  piModule = import ../modules/home-manager/flake-module.nix {
    inherit (inputs) pi-question pi-session-name pi-claude-auth;
    piWeb = ../packages/pi-web;
    aiSandbox = inputs.ai-sandbox.homeModules.default;
  };

  # A sentinel home and a stub sandbox package: nothing of a real machine reaches the output.
  base = {
    home = {
      username = "pi-setup";
      homeDirectory = "/@HOME@";
      stateVersion = "25.11";
    };
    programs.aiSandbox.package = stub "nono";
  };

  eval = extra:
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [piModule base extra];
    })
    .config;

  # F_P: the module with every built-in on (the package declares the full set; the Nix
  # defaults stay Nix policy). Without Nix pi owns `settings.json`, so the settings file is
  # not managed. pi-web is Nix-only and stays off.
  fp = eval {
    programs.aiSandbox.enable = true;
    programs.pi = {
      enable = true;
      settings.manage = false;
      builtinExtensions = {
        question.enable = true;
        sessionName.enable = true;
        staticWorkingIndicator.enable = true;
        webSearch.enable = true;
      };
      claudeAuth.enable = true;
    };
  };

  json = name: value: pkgs.writeText name (builtins.toJSON value);

  # The package manifest. Each registry entry maps to a package path: an extension of this
  # repository to its directory here, an extension from a flake input to the npm dependency
  # of the same package, pinned to the input's locked revision. An entry that maps to
  # nothing is an evaluation error, so no resource is Nix-only by accident.
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  lockNode = input: lock.nodes.${lock.nodes.root.inputs.${input}};
  pkgName = src: (builtins.fromJSON (builtins.readFile "${src}/package.json")).name;

  # Registry path prefix -> package path prefix, in lookup order; `dep` is the flake input
  # that npm installs as a dependency (null: a directory of this repository).
  roots =
    map (dep: {
      from = "${inputs.${dep}}";
      to = "./node_modules/${pkgName inputs.${dep}}";
      inherit dep;
    }) ["pi-question" "pi-session-name" "pi-claude-auth"]
    ++ [
      {
        # The registry links the store copy of this one directory (not of ../extensions).
        from = "${../extensions/static-working-indicator}";
        to = "./extensions/static-working-indicator";
        dep = null;
      }
      {
        from = "${../extensions/web-search}";
        to = "./extensions/web-search";
        dep = null;
      }
    ];

  # A registry path is a directory pi discovers through its `index.ts`, or the entry file.
  mapEntry = name: e: let
    path = toString e.path;
    r = lib.findFirst (r: path == r.from || lib.hasPrefix "${r.from}/" path) null roots;
    entry =
      if builtins.pathExists "${path}/index.ts"
      then "/index.ts"
      else if builtins.pathExists path
      then ""
      else throw "render: the extension ${name} has no entry file at ${path}";
  in
    if r == null
    then throw "render: no package path for the extension ${name} (${path})"
    else {
      inherit (r) dep;
      path = builtins.unsafeDiscardStringContext "${r.to}${lib.removePrefix r.from path}${entry}";
    };
  mapped = lib.mapAttrsToList mapEntry fp.programs.pi.extensions;

  dependencies = lib.listToAttrs (map (dep: let
    n = lockNode dep;
  in
    assert lib.assertMsg (n.locked.type == "github") "render: the input ${dep} is not a GitHub input";
      lib.nameValuePair (pkgName inputs.${dep}) "github:${n.original.owner}/${n.original.repo}#${n.locked.rev}")
  (lib.unique (lib.filter (d: d != null) (map (m: m.dep) mapped))));

  manifest = {
    name = "pi-setup";
    private = true;
    keywords = ["pi-package"];
    license = "MIT";
    description = "The pi extensions of pi-setup as a pi package: a question tool, session names, Claude subscription auth, a static working indicator and web search and fetch tools.";
    inherit dependencies;
    # What pi itself provides: never installed as a dependency.
    peerDependencies = lib.genAttrs [
      "@earendil-works/pi-agent-core"
      "@earendil-works/pi-ai"
      "@earendil-works/pi-coding-agent"
      "@earendil-works/pi-tui"
      "typebox"
    ] (_: "*");
    pi.extensions = map (m: m.path) mapped;
  };

  tree =
    pkgs.runCommand "pi-setup-rendered" {nativeBuildInputs = [pkgs.jq pkgs.gnugrep];}
    ''
      mkdir -p "$out/settings"
      jq -S . ${json "seed.json" fp.programs.pi.settings.seed} >"$out/settings/seed.json"
      jq -S . ${json "package.json" manifest} >"$out/package.json"

      # Hygiene: no store path and no sentinel home in a rendered file.
      ! grep -rlF -e /nix/store -e '@HOME@' "$out" || { echo "render: store path or sentinel home in a rendered file" >&2; exit 1; }
    '';

  # `nix run .#render`, from the repository root: the only writer of the rendered paths.
  app = pkgs.writeShellApplication {
    name = "pi-setup-render";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      if ! { [ -f render/default.nix ] && [ -f extensions/static-working-indicator/index.ts ]; }; then
        echo "run from the pi-setup repository root" >&2
        exit 2
      fi
      rm -rf package.json settings
      cp -r --no-preserve=mode ${tree}/. .
    '';
  };
in {inherit fp tree app;}
