# The two leaves a host fills from facts this module cannot know: the address
# of the search backend for the built-in web-search extension (./extensions.nix), which reads
# `PI_SEARX_URL`, and the health URL of the local model's server, declared here for a task
# router module to read (nothing in this repository reads it).
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
        The SearXNG instance for a web-search extension that reads `PI_SEARX_URL`, such as
        the built-in one (`builtinExtensions.webSearch.enable`), exported as that variable. Set it from the instance that
        actually runs (e.g. derived from the NixOS service), never from a literal. null: no
        variable. With `search.local.enable` it defaults to that instance's URL
        (./search-local.nix).
      '';
    };

    router.localHealthUrl = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "http://localhost:11545";
      description = ''
        The health URL of the local model's server. Declared for a task router module, which
        reads it as the health URL of its local model; this module and the economics bridge
        only carry it. null: unset.
      '';
    };
  };

  # Like every leaf of this module, only while pi is on.
  config = lib.mkIf (config.programs.pi.enable && config.programs.pi.search.searxUrl != null) {
    home.sessionVariables.PI_SEARX_URL = config.programs.pi.search.searxUrl;
  };
}
