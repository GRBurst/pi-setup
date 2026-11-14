# The pi module (`programs.pi`, the pi-setup module): pi's settings file, Claude dir and
# extension registry, on top of the sandbox module it imports (`aiSandbox`, the ai-sandbox flake's
# `homeModules.default`, passed in by ./flake-module.nix). Its sources (extensions, pi-web) come from
# ./flake-module.nix.
{aiSandbox}: {
  key = "pi-setup#pi";
  imports = [
    aiSandbox
    ./settings.nix
    ./claude-auth.nix
    ./actor-subagents.nix
    ./extensions.nix
    ./search.nix
    ./search-local.nix
    ./web.nix
  ];
}
