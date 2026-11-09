# The module checks of this repository, over the fixtures of ./lib.nix; wired by
# ../default.nix (derivations pi-setup-<name>).
{
  pkgs,
  lib,
  inputs,
  home-manager,
  piWeb,
}: let
  piLib = import ./lib.nix {inherit pkgs lib inputs home-manager piWeb;};
  inherit (piLib) mkAssertionCheck piFixtureWith piEvalFails;
  web = extra: {
    imports = [extra];
    programs.pi.web.enable = true;
  };
in {
  settings = import ./settings.nix {inherit lib pkgs piLib;};
  claude-auth = import ./claude-auth.nix {inherit lib pkgs piLib;};
  extensions = import ./extensions.nix {inherit lib pkgs inputs piLib;};
  search = import ./search.nix {inherit lib piLib;};
  search-local = import ./search-local.nix {inherit lib pkgs piLib;};
  search-local-run = import ./search-local-run.nix {inherit lib pkgs piLib;};
  web = import ./web.nix {inherit lib piLib;};

  fixtures = mkAssertionCheck "pi-setup-fixtures" [
    {
      # For the services too: isolation.enable = false starts nono directly
      # again, exactly as before the isolation.
      condition = let
        u = (piFixtureWith (web {programs.aiSandbox.isolation.enable = false;})).systemd.user.services.pi-web-server.Service;
        e = let
          v = u.ExecStart or "";
        in
          if lib.isList v
          then lib.concatStringsSep " " v
          else v;
      in
        lib.hasInfix "/bin/nono run --profile pi-web " e
        && !(lib.hasInfix "ai-sandbox-run" e)
        && !(lib.any (lib.hasPrefix "AI_SANDBOX_RELAX=") (u.Environment or []));
      message = "web-isolation-off: with isolation.enable = false the units must start nono directly";
    }
    {
      # The web UIs hand an agent with full tool access to anything that can
      # reach the port. The nono profile is the only boundary around that, so
      # an unsandboxed web UI must not be representable.
      condition = piEvalFails (web {programs.aiSandbox.enable = false;});
      message = "pi-web must refuse to run without programs.aiSandbox.enable";
    }
    {
      condition = piEvalFails (web {
        programs.aiSandbox.services.opencode-web = {
          enable = true;
          backendPort = 15433;
        };
      });
      message = "pi-web must refuse a port used twice";
    }
    {
      condition = !(piEvalFails (web {}));
      message = "the pi-web guards must not fire on a healthy configuration";
    }
  ];
}
