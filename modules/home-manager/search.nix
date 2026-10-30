# The two leaves a host fills from facts this module cannot know: the address
# of the search backend for a web-search extension that reads `PI_SEARX_URL` (none ships with
# this repository), and the health URL of the local model the task router prefers (read by
# ./economics-bridge.nix).
{
  config,
  lib,
  ...
}: {
  options.programs.pi = {
    search.searxUrl = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "http://127.0.0.1:8888";
      description = ''
        The SearXNG instance for a web-search extension that reads `PI_SEARX_URL` (none ships
        with this repository), exported as that variable. Set it from the instance that
        actually runs (e.g. derived from the NixOS service), never from a literal. null: no
        variable.
      '';
    };

    router.localHealthUrl = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "http://localhost:11545";
      description = ''
        The health URL of the local model's server, set as
        `taskRouter.settings.models.qwen-local.health` by the economics bridge. null: the
        task router's settings are left alone.
      '';
    };
  };

  # Like every leaf of this module, only while pi is on.
  config = lib.mkIf (config.programs.pi.enable && config.programs.pi.search.searxUrl != null) {
    home.sessionVariables.PI_SEARX_URL = config.programs.pi.search.searxUrl;
  };
}
