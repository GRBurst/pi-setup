# The two leaves the consumer sets from facts the pi module cannot know:
# `search.searxUrl` becomes `PI_SEARX_URL` when non-null, `router.localHealthUrl` is read by the
# economics bridge (here against a stub of the `programs.piEconomics` options). Wired by ./default.nix as
# pi-setup-search.
{
  lib,
  piLib,
}: let
  inherit (piLib) mkAssertionCheck piFixtureWith bridge piEconomicsStub;

  alone = piFixtureWith {};
  withUrl = piFixtureWith {programs.pi.search.searxUrl = "http://127.0.0.1:9999";};
  piOff = piFixtureWith {
    programs.pi.enable = false;
    programs.pi.search.searxUrl = "http://127.0.0.1:9999";
  };

  # The web-search built-in reads PI_SEARX_URL and never sets it.
  webSearch = extra:
    piFixtureWith {
      imports = [extra];
      programs.pi.builtinExtensions.webSearch.enable = true;
    };

  health = "http://example.invalid:11545";
  bridged = extra: piFixtureWith {imports = [bridge piEconomicsStub extra];};
  routed = bridged {programs.pi.router.localHealthUrl = health;};
  # A consumer that names the model keeps it; the bridge only adds the health leaf.
  routedWithModel = bridged {
    programs.pi.router.localHealthUrl = health;
    programs.piEconomics.taskRouter.settings.models.qwen-local.model = "llama/test";
  };
in
  mkAssertionCheck "pi-setup-search" [
    {
      condition = alone.programs.pi.search.searxUrl == null && !(alone.home.sessionVariables ? PI_SEARX_URL);
      message = "search: with searxUrl = null (the default) no PI_SEARX_URL variable exists";
    }
    {
      condition = withUrl.home.sessionVariables.PI_SEARX_URL == "http://127.0.0.1:9999";
      message = "search: a set searxUrl is exported as PI_SEARX_URL, verbatim";
    }
    {
      condition = (piFixtureWith {programs.pi.search.searxUrl = null;}).home.sessionVariables == alone.home.sessionVariables;
      message = "search: an explicit null is the default (no other variable is touched)";
    }
    {
      # Like every leaf of the module: nothing while pi is off.
      condition = !(piOff.home.sessionVariables ? PI_SEARX_URL);
      message = "search: with programs.pi.enable = false searxUrl exports no PI_SEARX_URL";
    }
    {
      condition =
        (webSearch {}).home.sessionVariables
        == alone.home.sessionVariables
        && (webSearch {programs.pi.search.searxUrl = "http://127.0.0.1:9999";}).home.sessionVariables
        == withUrl.home.sessionVariables;
      message = "search: the web-search built-in leaves searxUrl and PI_SEARX_URL as they are";
    }
    {
      condition = alone.programs.pi.router.localHealthUrl == null && (bridged {}).programs.piEconomics.taskRouter.settings == {};
      message = "router: localHealthUrl = null leaves the task router untouched";
    }
    {
      condition = routed.programs.piEconomics.taskRouter.settings == {models.qwen-local.health = health;};
      message = "router: the bridge maps localHealthUrl to taskRouter.settings.models.qwen-local.health";
    }
    {
      condition =
        routedWithModel.programs.piEconomics.taskRouter.settings.models.qwen-local
        == {
          model = "llama/test";
          inherit health;
        };
      message = "router: the health leaf merges with the consumer's own model entry";
    }
  ]
