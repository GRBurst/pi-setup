# The pi-setup `homeModules.default`: ./default.nix plus the defaults of the sources this
# flake brings as inputs (the pi-question, pi-session-name, pi-claude-auth and pi-actor-subagents
# extensions, the pi-web package expression) and the sandbox module ./default.nix imports
# (`aiSandbox`, the ai-sandbox flake's `homeModules.default`). Called with those six by the consumer.
{
  pi-question,
  pi-session-name,
  pi-claude-auth,
  pi-actor-subagents,
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
      programs.pi.actorSubagents.src = lib.mkDefault pi-actor-subagents;
      programs.pi.web.package = lib.mkDefault (pkgs.callPackage piWeb {});
    })
  ];
}
