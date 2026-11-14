# The economics bridge (the pi-setup `homeModules.piEconomics`): hands pi's
# extension registry, its agent dir and its settings file to the economics module (`programs.piEconomics`), which then renders the
# links, the existence assertions, the children's list and the `piSettingsMigrate` activation
# entry; and takes that children's list back for the actor-subagents settings file (the economics
# module renders the links then, its own extensions included). The local model's health URL
# (`programs.pi.router.localHealthUrl`) is not forwarded: a task router module reads it itself. Declares nothing and imports nothing: valid only next to a module that
# declares the `programs.piEconomics` options set and read here (the private layer's entry imports both).
{
  config,
  lib,
  ...
}: let
  p = config.programs.pi;
in {
  config = lib.mkIf p.enable {
    # The settings edits below run on the state file the pi module links, seeds and reclaims.
    assertions = [
      {
        assertion = p.settings.manage;
        message = "pi-setup: programs.pi.settings.manage = false leaves no state file for the economics bridge";
      }
    ];
    programs.pi.linkExtensions = false;
    # The economics module links the registry and writes relative settings entries under its agent dir:
    # pi's, so that pi finds them where it reads them, a moved agent dir included (without a trailing
    # slash, which the economics module's type refuses).
    programs.piEconomics.agentDir = lib.removeSuffix "/" p.agentDir;
    programs.piEconomics.extensions =
      lib.mapAttrs (_: e: {inherit (e) path checkPath input forChildren description;})
      p.extensions;
    # The economics module's settings edits run on the state file behind <agentDir>/settings.json,
    # after the pi module has seeded it and reclaimed a replaced link.
    programs.piEconomics.piSettings = {
      file = p.settings.stateFile;
      after = ["piSettingsSeed" "piSettingsReclaim"];
    };
    # No cycle: the economics module's list is read from the registry, never from the settings file.
    programs.pi.actorSubagents.childExtensions = config.programs.piEconomics.childExtensions;
  };
}
