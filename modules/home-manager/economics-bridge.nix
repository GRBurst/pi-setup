# The economics bridge (the pi-setup `homeModules.piEconomics`): hands pi's
# extension registry and its settings file to the economics module (`programs.piEconomics`), which then renders the
# links, the existence assertions, the children's list and the `piSettingsMigrate` activation
# entry, and the local model's health URL to its task router. Declares nothing and imports
# nothing: valid only next to a module that declares the `programs.piEconomics` options set
# here (the private layer's entry imports both).
{
  config,
  lib,
  ...
}: let
  p = config.programs.pi;
in {
  config = lib.mkIf p.enable (lib.mkMerge [
    {
      # The settings edits below run on the state file the pi module links, seeds and reclaims.
      assertions = [
        {
          assertion = p.settings.manage;
          message = "pi-setup: programs.pi.settings.manage = false leaves no state file for the economics bridge";
        }
      ];
      programs.pi.linkExtensions = false;
      programs.piEconomics.extensions =
        lib.mapAttrs (_: e: {inherit (e) path checkPath input forChildren description;})
        p.extensions;
      # The economics module's settings edits run on the state file behind <agentDir>/settings.json,
      # after the pi module has seeded it and reclaimed a replaced link.
      programs.piEconomics.piSettings = {
        file = p.settings.stateFile;
        after = ["piSettingsSeed" "piSettingsReclaim"];
      };
    }
    (lib.mkIf (p.router.localHealthUrl != null) {
      programs.piEconomics.taskRouter.settings.models.qwen-local.health = p.router.localHealthUrl;
    })
  ]);
}
