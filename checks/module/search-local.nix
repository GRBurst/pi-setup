# The on-demand loopback SearXNG (`search.local`) as data: the option tree, the settings
# template (JSON on, loopback bind, the secret a placeholder), the URL default, the scripts
# and the `pi`/`pi_nono` wrappers. Wired by ./default.nix as pi-setup-search-local; the
# scripts themselves run in ./search-local-run.nix.
{
  lib,
  piLib,
}: let
  inherit (piLib) mkAssertionCheck piFixtureWith piFailsWith;

  # The module form (for piFailsWith) and its evaluated config.
  localModule = extra: {
    imports = [extra];
    programs.pi.search.local.enable = true;
  };
  on = extra: piFixtureWith (localModule extra);

  plain = piFixtureWith {};
  local = on {};
  isoOff = {programs.aiSandbox.isolation.enable = false;};
  localIsoOff = on isoOff;
  plainIsoOff = piFixtureWith isoOff;

  url = "http://127.0.0.1:8888";
  placeholder = "@PI_SEARX_SECRET@";
  rendered = c: c.programs.pi.search.local.renderedSettings;
  commands = c: c.programs.pi.search.local.commands;
  names = c: map (p: p.name) c.home.packages;
  has = c: n: lib.elem n (names c);
  pkg = c: n: lib.findFirst (p: p.name == n) (throw "search-local: no package ${n}") c.home.packages;
  scripts = ["pi-searx-up" "pi-searx-down"];
  wrappers = ["pi-with-search" "pi_nono-with-search"];

  # The wrapper runs pi-searx-up (never fatal, off stdin: a piped prompt is pi's), exports the
  # URL, then the alias's own line.
  wrapperRuns = c: name: command:
    lib.hasInfix ''
      pi-searx-up </dev/null || true
      export PI_SEARX_URL=${lib.escapeShellArg c.programs.pi.search.searxUrl}
      ${command} "$@"
    ''
    (pkg c name).text;

  merged = rendered (on {
    programs.pi.search.local.settings = {
      search.safe_search = 1;
      use_default_settings.engines.keep_only = ["wikipedia"];
      server.image_proxy = true;
    };
  });
in
  mkAssertionCheck "pi-setup-search-local" [
    {
      condition =
        !plain.programs.pi.search.local.enable
        && plain.programs.pi.search.searxUrl == null
        && lib.all (n: !(has plain n)) (scripts ++ wrappers)
        && (piFixtureWith {programs.pi.search.local.port = 9999;}).home.shellAliases == plain.home.shellAliases;
      message = "search-local: off by default; its other options alone change no alias, URL or package";
    }
    {
      condition = local.programs.pi.search.searxUrl == url && local.home.sessionVariables.PI_SEARX_URL == url;
      message = "search-local: enabled, searxUrl defaults to http://127.0.0.1:<port> (default port 8888) and is exported as PI_SEARX_URL";
    }
    {
      condition = let
        c = on {programs.pi.search.local.port = 18080;};
      in
        c.programs.pi.search.searxUrl == "http://127.0.0.1:18080" && (rendered c).server.port == 18080;
      message = "search-local: port moves both the URL and the rendered server.port";
    }
    {
      condition = let
        c = on {programs.pi.search.searxUrl = "http://127.0.0.1:9999";};
      in
        c.programs.pi.search.searxUrl
        == "http://127.0.0.1:9999"
        && lib.any (lib.hasPrefix "pi-setup: programs.pi.search.local.enable is on but programs.pi.search.searxUrl") c.warnings
        && !(lib.any (lib.hasPrefix "pi-setup: programs.pi.search.local") local.warnings);
      message = "search-local: an explicit searxUrl wins over the default, with a warning that the local instance goes unused";
    }
    {
      condition = let
        r = rendered local;
      in
        r.use_default_settings
        == true
        && r.server.bind_address == "127.0.0.1"
        && r.server.port == 8888
        && r.server.limiter == false
        && r.server.public_instance == false
        && lib.elem "json" r.search.formats
        && lib.elem "html" r.search.formats;
      message = "search-local: the rendered settings keep upstream defaults (engines included), bind 127.0.0.1, enable the JSON format and switch the limiter off";
    }
    {
      # The per-user secret is generated at the first start into the state dir (0600); the
      # store holds only the placeholder pi-searx-up replaces.
      condition = (rendered local).server.secret_key == placeholder && lib.hasInfix placeholder (builtins.readFile ../../scripts/pi-searx.sh);
      message = "search-local: the settings template in the store holds the secret placeholder, never a secret";
    }
    {
      condition =
        merged.search.safe_search
        == 1
        && merged.use_default_settings == {engines.keep_only = ["wikipedia"];}
        && merged.server.image_proxy == true
        && merged.server.bind_address == "127.0.0.1"
        && merged.server.secret_key == placeholder
        && merged.search.formats == ["html" "json"];
      message = "search-local: settings merge key by key over the base (engines through use_default_settings); bind, port, secret and formats stay";
    }
    {
      condition =
        piFailsWith "pi-setup: programs.pi.search.local.settings.server.bind_address" (localModule {programs.pi.search.local.settings.server.bind_address = "0.0.0.0";})
        && piFailsWith "pi-setup: programs.pi.search.local.settings.server.port" (localModule {programs.pi.search.local.settings.server.port = 9000;})
        && piFailsWith "pi-setup: programs.pi.search.local.settings.server.secret_key" (localModule {programs.pi.search.local.settings.server.secret_key = "x";});
      message = "search-local: settings cannot set server.bind_address (loopback only), server.port (the option) or server.secret_key (per user, at start)";
    }
    {
      condition =
        piFailsWith "pi-setup: programs.pi.search.local.settings.search.formats" (localModule {programs.pi.search.local.settings.search.formats = ["html"];})
        && (rendered (on {programs.pi.search.local.settings.search.formats = ["html" "json" "csv"];})).search.formats == ["html" "json" "csv"];
      message = "search-local: search.formats may grow but must keep json (pi's backend asks for format=json; without it SearXNG answers 403)";
    }
    {
      condition = lib.all (has local) (scripts ++ wrappers);
      message = "search-local: enabled with the sandbox and its isolation, it installs pi-searx-up, pi-searx-down, pi-with-search and pi_nono-with-search";
    }
    {
      condition = local.home.shellAliases.pi == "pi-with-search" && local.home.shellAliases.pi_nono == "pi_nono-with-search";
      message = "search-local: the pi and pi_nono aliases run the wrappers";
    }
    {
      # The wrappers run exactly what ai-sandbox's aliases hold without local search: the
      # nono-only line of pi_nono is derived from render.command and must not drift from it.
      condition = commands local == {inherit (plain.home.shellAliases) pi pi_nono;};
      message = "search-local: the wrappers' command lines equal ai-sandbox's own pi and pi_nono aliases";
    }
    {
      condition =
        wrapperRuns local "pi-with-search" plain.home.shellAliases.pi
        && wrapperRuns local "pi_nono-with-search" plain.home.shellAliases.pi_nono;
      message = "search-local: each wrapper runs pi-searx-up (never fatal, stdin left to pi), exports PI_SEARX_URL, then its alias's line with the arguments";
    }
    {
      condition =
        localIsoOff.home.shellAliases.pi
        == "pi-with-search"
        && !(localIsoOff.home.shellAliases ? pi_nono)
        && !(has localIsoOff "pi_nono-with-search")
        && commands localIsoOff == {inherit (plainIsoOff.home.shellAliases) pi;}
        && wrapperRuns localIsoOff "pi-with-search" plainIsoOff.home.shellAliases.pi;
      message = "search-local: with the isolation off, only pi exists (nono only) and its wrapper runs that line";
    }
    {
      condition = let
        c = on {programs.aiSandbox.enable = false;};
      in
        lib.all (has c) scripts
        && lib.all (n: !(has c n)) wrappers
        && !(c.home.shellAliases ? pi)
        && c.home.sessionVariables.PI_SEARX_URL == url;
      message = "search-local: without the sandbox, the scripts and the URL only (no alias to wrap)";
    }
    {
      condition = let
        c = on {programs.aiSandbox.harnesses.pi.enable = false;};
      in
        lib.all (has c) scripts && lib.all (n: !(has c n)) wrappers && !(c.home.shellAliases ? pi);
      message = "search-local: without the pi harness, the scripts only";
    }
    {
      condition = let
        c = on {programs.aiSandbox.extraAliases.pi = "my-pi";};
      in
        c.home.shellAliases.pi == "my-pi" && c.home.shellAliases.pi_nono == "pi_nono-with-search";
      message = "search-local: a consumer's own pi alias (extraAliases) wins over the wrapper";
    }
    {
      condition = let
        c = on {programs.pi.search.searxUrl = "${url}/";};
      in
        !(lib.any (lib.hasPrefix "pi-setup: programs.pi.search.local") c.warnings);
      message = "search-local: a searxUrl that differs from the local one by a trailing slash only draws no warning";
    }
    {
      # reuseExisting: on by default (the NixOS searx on the port runs as another user); the
      # scripts carry it; off, the wrapper starts pi without the URL when pi-searx-up fails.
      condition = let
        strict = on {programs.pi.search.local.reuseExisting = false;};
        remote = on {
          programs.pi.search.local.reuseExisting = false;
          programs.pi.search.searxUrl = "http://127.0.0.1:9999";
        };
        up = c: (pkg c "pi-searx-up").text;
      in
        local.programs.pi.search.local.reuseExisting
        && lib.hasInfix "\nPI_SEARX_REUSE=1\n" (up local)
        && lib.hasInfix "\nPI_SEARX_REUSE=0\n" (up strict)
        && lib.hasInfix "if pi-searx-up </dev/null; then\n  export PI_SEARX_URL=${lib.escapeShellArg url}\nelse\n  unset PI_SEARX_URL\nfi\n" (pkg strict "pi-with-search").text
        && !(lib.hasInfix "unset PI_SEARX_URL" (pkg local "pi-with-search").text)
        && !(lib.hasInfix "unset PI_SEARX_URL" (pkg remote "pi-with-search").text);
      message = "search-local: reuseExisting defaults to true; off, the scripts refuse a foreign server and the wrapper drops PI_SEARX_URL when pi-searx-up fails (not when searxUrl points elsewhere)";
    }
    {
      condition = let
        c = on {programs.pi.enable = false;};
      in
        lib.all (n: !(has c n)) (scripts ++ wrappers)
        && !(c.home.sessionVariables ? PI_SEARX_URL)
        && c.home.shellAliases == (piFixtureWith {programs.pi.enable = false;}).home.shellAliases;
      message = "search-local: with programs.pi.enable = false nothing of it exists";
    }
  ]
