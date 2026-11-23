# The leaves a host fills from facts this module cannot know: the address
# of the search backend for the built-in web-search extension (./extensions.nix), which reads
# `PI_SEARX_URL`, the proxy its web_fetch goes through (`PI_WEB_FETCH_PROXY`), and the health URL of the local model's server, declared here for a task
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

    search.fetchProxy = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "env";
      description = ''
        The HTTP proxy the built-in `web_fetch` goes through, exported as `PI_WEB_FETCH_PROXY`,
        for a machine whose only way out is a proxy. `"env"`: the proxy variables pi starts
        with (`https_proxy`/`HTTPS_PROXY` for https targets, `http_proxy`/`HTTP_PROXY` for
        http, `all_proxy`/`ALL_PROXY` as fallback, `no_proxy`/`NO_PROXY` going direct);
        `"http://[user:password@]host:port"`: that proxy for every target. Every target goes
        through a CONNECT tunnel to the address web_fetch checked. null: no variable, direct
        connections.
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
  config = lib.mkIf config.programs.pi.enable {
    home.sessionVariables =
      lib.optionalAttrs (config.programs.pi.search.searxUrl != null) {PI_SEARX_URL = config.programs.pi.search.searxUrl;}
      // lib.optionalAttrs (config.programs.pi.search.fetchProxy != null) {PI_WEB_FETCH_PROXY = config.programs.pi.search.fetchProxy;};
  };
}
