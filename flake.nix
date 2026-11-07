{
  description = "Pi coding agent in the AI sandbox (public layer); works without Nix, first-class Nix support as Home Manager modules";

  inputs = {
    # Pinned revisions; consumers `follows` their own.
    nixpkgs.url = "github:NixOS/nixpkgs/31ecbaca1bdefa45dffc409f0250bd8039ea0010";
    home-manager = {
      url = "github:nix-community/home-manager/1e3ebeb683d055d1675d3f64e6d2b186cb2ee504";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ai-sandbox = {
      url = "github:GRBurst/ai-sandbox";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    # Supply chain: extension code runs with pi's privileges inside the sandbox;
    # pinned by rev, never bumped blind.
    pi-question = {
      url = "github:fdietze/pi-question/1f5e8cdf9f2f7cb197181ef53b4bc64ee42e1a76";
      flake = false;
    };
    pi-session-name = {
      url = "github:fdietze/pi-session-name/96078fde560d4edc146a7051e950466806e7101e";
      flake = false;
    };
    # The unpatched upstream; a consumer may replace it through `programs.pi.claudeAuth.package`.
    pi-claude-auth = {
      url = "github:fdietze/pi-claude-auth/79972e362fa3d61b0bce4850fbb27e8927c35c6c";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    ai-sandbox,
    pi-question,
    pi-session-name,
    pi-claude-auth,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forSystems = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
    renderOf = pkgs:
      import ./render {
        inherit pkgs home-manager;
        inherit (nixpkgs) lib;
        inputs = self.inputs;
      };
  in {
    homeModules.default = import ./modules/home-manager/flake-module.nix {
      inherit pi-question pi-session-name pi-claude-auth;
      piWeb = ./packages/pi-web;
      aiSandbox = ai-sandbox.homeModules.default;
    };

    # The economics bridge, a path: a module that declares `programs.piEconomics` imports it.
    homeModules.piEconomics = ./modules/home-manager/economics-bridge.nix;

    packages = forSystems (_: pkgs: {
      pi-web = pkgs.callPackage ./packages/pi-web {};
    });

    # The render tree, exposed so it can be built and inspected on its own.
    legacyPackages = forSystems (_: pkgs: {render-tree = (renderOf pkgs).tree;});

    # `nix run .#render` writes the rendered paths into the checkout.
    apps = forSystems (_: pkgs: {
      render = {
        type = "app";
        program = nixpkgs.lib.getExe (renderOf pkgs).app;
        meta.description = "Write the rendered pi package manifest and settings seed into the checkout";
      };
    });

    formatter = forSystems (_: pkgs: pkgs.alejandra);

    checks = forSystems (_: pkgs:
      import ./checks {
        inherit pkgs self home-manager;
        inherit (nixpkgs) lib;
        render = renderOf pkgs;
      });
  };
}
