# The README's primary path composes: `examples/existing-flake` evaluated offline, with this
# flake as its `pi-setup` input and this flake's nixpkgs, home-manager and ai-sandbox as the
# consumer's (what `follows` resolves to).
#
# - the example's inputs are exactly `ai-sandbox`, `home-manager`, `nixpkgs` and `pi-setup`,
#   with the URLs the README gives and the `follows` that tie them to one nixpkgs,
#   home-manager and sandbox;
# - `homeConfigurations` is exactly [tester], the activation package evaluates, the sandbox and
#   pi are on;
# - a second import of `homeModules.default` evaluates to the same result (module key dedup);
# - the example installs pi itself (`programs.pi.package`), so the README's `pi` is on PATH.
{
  pkgs,
  lib,
  self,
  home-manager,
}: let
  inherit
    (import ./module/lib.nix {
      inherit pkgs lib home-manager;
      inputs = self.inputs;
      piWeb = ../packages/pi-web;
    })
    mkAssertionCheck
    ;

  dir = "${self}/examples/existing-flake";
  present = builtins.pathExists "${dir}/flake.nix";
  # absent: the empty flake, so the first message names the missing file
  flake =
    if present
    then import "${dir}/flake.nix"
    else {};
  outputs =
    if present
    then
      flake.outputs {
        self = outputs // {outPath = dir;};
        pi-setup = self;
        ai-sandbox = self.inputs.ai-sandbox;
        inherit (self.inputs) nixpkgs home-manager;
      }
    else {};
  ins = flake.inputs or {};
  hcs = outputs.homeConfigurations or {};
  hc = hcs.tester or null;
  ok = present && hc != null;
  c = hc.config;
  twice = hc.extendModules {modules = [self.homeModules.default];};

  sorted = lib.sort (a: b: a < b);
  # a condition that reads the configuration is only evaluated when there is one
  needs = cond: ok && cond;
  piInstalled = name: lib.any (p: (p.pname or p.name or "") == name) c.home.packages;
in
  mkAssertionCheck "existing-flake-example" [
    {
      condition = present;
      message = "examples/existing-flake/flake.nix does not exist";
    }
    {
      condition = (ins.pi-setup.url or null) == "github:GRBurst/pi-setup";
      message = "inputs.pi-setup.url is not github:GRBurst/pi-setup";
    }
    {
      condition = (ins.ai-sandbox.url or null) == "github:GRBurst/ai-sandbox";
      message = "inputs.ai-sandbox.url is not github:GRBurst/ai-sandbox";
    }
    {
      condition = (ins.ai-sandbox.inputs.nixpkgs.follows or null) == "nixpkgs";
      message = "inputs.ai-sandbox.inputs.nixpkgs does not follow nixpkgs";
    }
    {
      condition = (ins.ai-sandbox.inputs.home-manager.follows or null) == "home-manager";
      message = "inputs.ai-sandbox.inputs.home-manager does not follow home-manager";
    }
    {
      condition = (ins.home-manager.inputs.nixpkgs.follows or null) == "nixpkgs";
      message = "inputs.home-manager.inputs.nixpkgs does not follow nixpkgs";
    }
    {
      condition = (ins.pi-setup.inputs.nixpkgs.follows or null) == "nixpkgs";
      message = "inputs.pi-setup.inputs.nixpkgs does not follow nixpkgs";
    }
    {
      condition = (ins.pi-setup.inputs.home-manager.follows or null) == "home-manager";
      message = "inputs.pi-setup.inputs.home-manager does not follow home-manager";
    }
    {
      condition = (ins.pi-setup.inputs.ai-sandbox.follows or null) == "ai-sandbox";
      message = "inputs.pi-setup.inputs.ai-sandbox does not follow ai-sandbox";
    }
    {
      condition = sorted (lib.attrNames ins) == ["ai-sandbox" "home-manager" "nixpkgs" "pi-setup"];
      message = "the example's inputs are not exactly ai-sandbox, home-manager, nixpkgs and pi-setup: ${toString (lib.attrNames ins)}";
    }
    {
      condition = lib.attrNames hcs == ["tester"];
      message = "homeConfigurations is not exactly [tester]";
    }
    {
      condition = needs (builtins.isString c.home.activationPackage.drvPath);
      message = "the activation package does not evaluate";
    }
    {
      condition = needs c.programs.aiSandbox.enable;
      message = "programs.aiSandbox.enable is off";
    }
    {
      condition = needs c.programs.pi.enable;
      message = "programs.pi.enable is off";
    }
    {
      condition = needs (piInstalled "pi-coding-agent");
      message = "programs.pi.package does not install pi-coding-agent into home.packages";
    }
    {
      condition = needs (twice.config.home.activationPackage.drvPath == c.home.activationPackage.drvPath);
      message = "importing homeModules.default a second time changes the result (module key dedup)";
    }
  ]
