# The pi-setup `homeModules.default`: ./default.nix plus the defaults of the sources this
# flake brings as inputs (the pi-question, pi-session-name and pi-claude-auth extensions, the
# pi-web package expression) and the sandbox module ./default.nix imports (`aiSandbox`, the
# ai-sandbox flake's `homeModules.default`). Called with those five by the consumer.
{
  pi-question,
  pi-session-name,
  pi-claude-auth,
  piWeb,
  aiSandbox,
}: {
  key = "pi-setup#homeModules.default";
  imports = [
    (import ./default.nix {inherit aiSandbox;})
    ({
      lib,
      pkgs,
      ...
    }: {
      programs.pi.builtinExtensions.question.src = lib.mkDefault pi-question;
      programs.pi.builtinExtensions.sessionName.src = lib.mkDefault pi-session-name;
      programs.pi.claudeAuth.src = lib.mkDefault pi-claude-auth;
      programs.pi.web.package = lib.mkDefault (pkgs.callPackage piWeb {});
    })
  ];
}
