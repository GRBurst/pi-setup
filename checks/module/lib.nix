# Fixtures and helpers of the module checks of this repository.
# The pi module alone (`piModule`, pi-setup's `homeModules.default`, over bare nixpkgs with the
# sandbox module's stub fixture base); `inputs` supplies only pi-setup's own inputs
# (pi-question, pi-session-name, pi-claude-auth, and ai-sandbox, whose `checks/module/lib.nix` gives the fixture base); `piWeb` is the pi-web package expression the flake module takes.
{
  pkgs,
  lib,
  inputs,
  home-manager,
  piWeb,
}: rec {
  sandbox = import "${inputs.ai-sandbox}/checks/module/lib.nix" {inherit pkgs lib home-manager;};

  piModule = import ../../modules/home-manager/flake-module.nix {
    inherit (inputs) pi-question pi-session-name pi-claude-auth;
    aiSandbox = inputs.ai-sandbox.homeModules.default;
    inherit piWeb;
  };

  piBase = {programs.pi.enable = lib.mkDefault true;};

  # The economics bridge (pi-setup's `homeModules.piEconomics`).
  bridge = ../../modules/home-manager/economics-bridge.nix;

  # The four `programs.piEconomics` options the bridge sets, loosely typed: a field the bridge does not
  # forward is absent here, not defaulted.
  piEconomicsStub = {
    options.programs.piEconomics = {
      extensions = lib.mkOption {
        type = with lib.types; attrsOf (attrsOf anything);
        default = {};
      };
      piSettings.file = lib.mkOption {
        type = lib.types.str;
        default = "unset";
      };
      piSettings.after = lib.mkOption {
        type = with lib.types; listOf str;
        default = [];
      };
      taskRouter.settings = lib.mkOption {
        type = with lib.types; attrsOf anything;
        default = {};
      };
    };
  };

  # The pi module plus one override (sandbox on, its package a stub).
  piFixtureWith = extra:
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [piModule sandbox.fixtureBase piBase extra];
    })
    .config;

  # As the sandbox helpers' aiFailedWith: the failed assertions' messages, as data.
  piFailedWith = extra:
    map (a: a.message) (lib.filter (a: !a.assertion)
      (sandbox.hmLib.evalModules {
        class = "homeManager";
        specialArgs.modulesPath = "${home-manager}/modules";
        modules =
          [piModule sandbox.fixtureBase piBase extra]
          ++ import "${home-manager}/modules/modules.nix" {
            inherit pkgs;
            lib = sandbox.hmLib;
            check = true;
          };
      })
      .config
      .assertions);

  piFailsWith = prefix: extra: let
    f = piFailedWith extra;
  in
    lib.length f == 1 && lib.hasPrefix prefix (lib.head f);

  mkAssertionCheck = name: assertions:
    pkgs.runCommand name {passthru.messages = map (a: a.message) assertions;} ''
      ${lib.concatMapStringsSep "\n" (assertion: ''
          if [ "${
            if assertion.condition
            then "1"
            else "0"
          }" != "1" ]; then
            echo ${lib.escapeShellArg assertion.message} >&2
            exit 1
          fi
        '')
        assertions}
      touch "$out"
    '';

  # Home Manager's evalModules wrapper turns a failed assertion into a THROW on any access to
  # `config`, so a guard that fired cannot always be read back as data (`piFailedWith` does, for a
  # message). Observing the throw is the other signal; it is specific enough when the healthy
  # configuration is proven to fail none, so each broken fixture has exactly one assertion that
  # can fail.
  piEvalFails = extra:
    !(builtins.tryEval
      (builtins.deepSeq (piFixtureWith extra).assertions true))
    .success;
}
