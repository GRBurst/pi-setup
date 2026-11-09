# The on-demand loopback SearXNG (`search.local`) as data: the option tree, the settings
# template (JSON on, loopback bind, the secret a placeholder), the URL default, the scripts
# and the pre-start hook of ai-sandbox's pi harness. Wired by ./default.nix as
# pi-setup-search-local; the scripts themselves run in ./search-local-run.nix.
{
  lib,
  pkgs,
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
  hookFile = c: c.programs.aiSandbox.internal.preStartFiles.pi;
  # String context off: hasInfix matches by regex, which refuses a store path.
  noCtx = builtins.unsafeDiscardStringContext;
  hookText = c: noCtx (hookFile c).text;
  envExe = noCtx (lib.getExe' pkgs.coreutils "env");
  upExe = c: noCtx (lib.getExe (pkg c "pi-searx-up"));
  # The segment ai-sandbox puts in every alias of the harness.
  segment = c: noCtx "{ . ${hookFile c} || :; }";
  aliasNames = ["pi" "pi_nono"];
  hooked = c: lib.all (n: lib.hasInfix (segment c) (noCtx c.home.shellAliases.${n})) aliasNames;
  names = c: map (p: p.name) c.home.packages;
  has = c: n: lib.elem n (names c);
  pkg = c: n: lib.findFirst (p: p.name == n) (throw "search-local: no package ${n}") c.home.packages;
  scripts = ["pi-searx-up" "pi-searx-down"];
  wrappers = ["pi-with-search" "pi_nono-with-search"];

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
        && plain.programs.aiSandbox.internal.preStartFiles == {}
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
      condition = lib.all (has local) scripts && lib.all (n: !(has local n)) wrappers;
      message = "search-local: enabled, it installs pi-searx-up and pi-searx-down and no pi-with-search or pi_nono-with-search wrapper";
    }
    {
      # The hook is ai-sandbox's: the aliases are its own lines (plain's, plus the segment),
      # not a wrapper's name, and nothing of this module overrides them.
      condition =
        local.programs.aiSandbox.internal.preStartFiles ? pi
        && hooked local
        && !(plain.home.shellAliases.pi == local.home.shellAliases.pi)
        && lib.all (n: lib.hasInfix "exec " local.home.shellAliases.${n} && !(lib.hasInfix "with-search" local.home.shellAliases.${n})) aliasNames
        && lib.all (n: lib.hasInfix "-- pi " local.home.shellAliases.${n}) aliasNames
        && local.programs.aiSandbox.extraAliases == {};
      message = "search-local: enabled, the pi and pi_nono aliases are ai-sandbox's own and source the pi pre-start hook (no wrapper, no extraAliases)";
    }
    {
      # pi-searx-up runs from the hook with pi's per-CLI TMPDIR unset: the daemon outlives pi
      # and must not keep a directory the sandboxed pi can write. The URL is exported for pi.
      condition =
        lib.hasInfix "${envExe} -u TMPDIR ${upExe local}" (hookText local)
        && lib.hasInfix "export PI_SEARX_URL=${lib.escapeShellArg url}" (hookText local)
        && !(lib.hasInfix "unset PI_SEARX_URL" (hookText local));
      message = "search-local: the hook starts pi-searx-up with TMPDIR unset (a daemon must not keep pi's TMPDIR), never fatally, and exports PI_SEARX_URL";
    }
    {
      condition =
        localIsoOff.programs.aiSandbox.internal.preStartFiles ? pi
        && lib.hasInfix (segment localIsoOff) (noCtx localIsoOff.home.shellAliases.pi)
        && !(localIsoOff.home.shellAliases ? pi_nono)
        && !(has localIsoOff "pi_nono-with-search")
        && plainIsoOff.programs.aiSandbox.internal.preStartFiles == {};
      message = "search-local: with the isolation off, only pi exists (nono only) and it sources the hook";
    }
    {
      condition = let
        c = on {programs.aiSandbox.enable = false;};
      in
        lib.all (has c) scripts
        && !(c.home.shellAliases ? pi)
        && c.home.sessionVariables.PI_SEARX_URL == url;
      message = "search-local: without the sandbox, the scripts and the URL only (no alias, no hook)";
    }
    {
      condition = let
        c = on {programs.aiSandbox.harnesses.pi.enable = false;};
      in
        lib.all (has c) scripts && !(c.home.shellAliases ? pi) && c.programs.aiSandbox.internal.preStartFiles == {};
      message = "search-local: without the pi harness, the scripts only (no alias, no hook file)";
    }
    {
      condition = let
        c = on {programs.aiSandbox.extraAliases.pi = "my-pi";};
      in
        c.home.shellAliases.pi == "my-pi" && lib.hasInfix (segment c) (noCtx c.home.shellAliases.pi_nono);
      message = "search-local: a consumer's own pi alias (extraAliases) stays its own text, without the hook; pi_nono keeps it";
    }
    {
      # A variant of the pi harness and its twin source the hook too (the old wrappers missed them).
      condition = let
        c = on {
          programs.aiSandbox.variants.pi_notes = {
            harness = "pi";
            suffix = "notes";
          };
        };
      in
        lib.all (n: lib.hasInfix (segment c) (noCtx c.home.shellAliases.${n})) ["pi" "pi_nono" "pi_notes" "pi_notes_nono"];
      message = "search-local: every pi variant and its _nono twin sources the hook";
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
        && lib.hasInfix "if ${envExe} -u TMPDIR ${upExe strict}; then\n  export PI_SEARX_URL=${lib.escapeShellArg url}\nelse\n  unset PI_SEARX_URL\nfi\n" (hookText strict)
        && !(lib.hasInfix "unset PI_SEARX_URL" (hookText local))
        && !(lib.hasInfix "unset PI_SEARX_URL" (hookText remote));
      message = "search-local: reuseExisting defaults to true; off, the scripts refuse a foreign server and the hook drops PI_SEARX_URL when pi-searx-up fails (not when searxUrl points elsewhere)";
    }
    {
      condition = let
        c = on {programs.pi.enable = false;};
      in
        lib.all (n: !(has c n)) (scripts ++ wrappers)
        && c.programs.aiSandbox.internal.preStartFiles == {}
        && !(c.home.sessionVariables ? PI_SEARX_URL)
        && c.home.shellAliases == (piFixtureWith {programs.pi.enable = false;}).home.shellAliases;
      message = "search-local: with programs.pi.enable = false nothing of it exists";
    }
  ]
