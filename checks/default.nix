{
  pkgs,
  lib,
  self,
  home-manager,
  render,
}: let
  # Disjoint union of check sets: a duplicate check name is an evaluation error.
  union = lib.foldl' (acc: s: let
    dup = lib.intersectLists (lib.attrNames acc) (lib.attrNames s);
  in
    if dup == []
    then acc // s
    else throw "checks: duplicate check names: ${toString dup}") {};

  # One Home Manager evaluation, shared by the option-table check.
  hm = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      self.homeModules.default
      {
        home = {
          username = "tester";
          homeDirectory = "/home/tester";
          stateVersion = "26.05";
        };
      }
    ];
  };

  all = union [
    {
      # Every `.nix` file in the tree is Alejandra-formatted.
      formatting = pkgs.runCommand "formatting" {nativeBuildInputs = [pkgs.alejandra];} ''
        cd ${self}
        alejandra --check . || {
          echo "formatting: run alejandra on the files above" >&2
          exit 1
        }
        touch $out
      '';

      # Generic personal-data scan of the source, self-tested on fixtures.
      leaks = import ./leaks {inherit pkgs self;};

      # Every leaf option under programs.pi is named in the README table.
      readme-options = import ./readme-options.nix {
        inherit pkgs lib self;
        inherit (hm) options;
        root = "pi";
      };

      # The README's sections, the words a user needs in them, and its commands.
      readme-sections = import ./readme-sections.nix {inherit pkgs lib self home-manager;};

      # The example flake for an existing Home Manager flake evaluates as the README says.
      existing-flake-example = import ./existing-flake.nix {inherit pkgs lib self home-manager;};
    }
    {
      # Every tracked `*.sh` is checked or excluded by name; the checked ones are clean.
      shellcheck = import ./shellcheck.nix {inherit pkgs lib self;};

      # The CI workflow is valid.
      actionlint = import ./actionlint.nix {inherit pkgs self;};

      # Every `docs/*.md` citation exists; no tracked file cites a decision or task id.
      doc-refs = import ./doc-refs.nix {inherit pkgs self;};

      # The pi-web settings prune keeps every entry that is not a dangling store path.
      agent-web-prune = pkgs.callPackage ./agent-web-prune {};

      # The modules and packages name no host coupling; no module reads a rendered file.
      boundary = import ./boundary.nix {inherit pkgs lib home-manager self;};

      # The pi package manifest: its paths exist, pi's own packages are peers only.
      pi-package-manifest = import ./pi-package.nix {inherit pkgs lib self;};

      # The repository installs as a pi package offline, and pi loads its extensions.
      pi-install-smoke = import ./pi-install-smoke.nix {inherit pkgs self;};

      # The web-search extension's tests, offline with an injected transport and resolver.
      web-search = import ./web-search {inherit pkgs lib;};
    }
    # The committed rendered paths against the render fixture's output.
    (import ./render.nix {inherit pkgs lib self render;})
    # The pi module and the economics bridge against fixture users (rows per option group).
    (import ./module {
      inherit pkgs lib home-manager;
      inputs = self.inputs;
      piWeb = ../packages/pi-web;
    })
  ];
in
  all
