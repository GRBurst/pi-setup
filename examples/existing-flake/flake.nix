{
  description = "An existing Home Manager flake with the pi-setup module added";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Added: the sandbox, on your nixpkgs and home-manager.
    ai-sandbox = {
      url = "github:GRBurst/ai-sandbox";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    # Added: the pi modules, on the same nixpkgs, home-manager and sandbox.
    pi-setup = {
      url = "github:GRBurst/pi-setup";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
        ai-sandbox.follows = "ai-sandbox";
      };
    };
  };

  outputs = {
    nixpkgs,
    home-manager,
    pi-setup,
    ...
  }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    homeConfigurations.tester = home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        {
          home = {
            username = "tester";
            homeDirectory = "/home/tester";
            stateVersion = "26.05";
          };
        }
        # Added: the module, with the sandbox and pi switched on.
        pi-setup.homeModules.default
        {
          programs.aiSandbox.enable = true;
          programs.pi.enable = true;
          programs.pi.package = pkgs.pi-coding-agent;
        }
      ];
    };
  };
}
