# An on-demand, loopback-only SearXNG for a web-search extension that reads `PI_SEARX_URL`
# (`programs.pi.search.local`), for a machine without NixOS and without a systemd user
# session (a container); it works the same where both exist. No service and no unit:
# `pi-searx-up` starts it when nothing answers on the port (idempotent; state, pid, log and
# the per-user secret under `$XDG_STATE_HOME/pi-searx`, see ../../scripts/pi-searx.sh),
# `pi-searx-down` stops the instance it started, and the `pi` and `pi_nono` aliases run
# wrappers that call `pi-searx-up` before the sandboxed pi.
#
# SearXNG runs outside the sandbox. pi reaches it over loopback TCP, which nothing in the
# way restricts: the pi pack's nono network policy is `block: false` with no proxy (so no
# `open_port` grant is needed), and the namespace isolation (ai-sandbox-run) has no network
# layer. Its state dir is no grant of the pi profile, so the agent cannot read the secret.
{
  config,
  lib,
  pkgs,
  ...
}: let
  pcfg = config.programs.pi;
  cfg = pcfg.search.local;
  scfg = config.programs.aiSandbox;
  isolationEnabled = scfg.enable && scfg.isolation.enable;

  url = "http://127.0.0.1:${toString cfg.port}";
  placeholder = "@PI_SEARX_SECRET@";
  # A searxUrl is the local server's when it differs from `url` by a trailing slash only.
  isLocalUrl = u: u != null && lib.removeSuffix "/" u == url;
  refuseForeign = !cfg.reuseExisting;

  # The base under `settings`: upstream's defaults (their engines included), loopback-only
  # use without valkey (no limiter), and the JSON format pi's backend asks for (SearXNG's
  # default, html only, answers format=json with 403). The keys of `owned` are the module's.
  base = {
    use_default_settings = true;
    server = {
      limiter = false;
      public_instance = false;
    };
    search.formats = ["html" "json"];
  };
  owned = {
    bind_address = "127.0.0.1";
    port = cfg.port;
    secret_key = placeholder;
  };
  rendered = lib.recursiveUpdate (lib.recursiveUpdate base cfg.settings) {server = owned;};
  template = (pkgs.formats.yaml {}).generate "pi-searx-settings.yml" rendered;
  userServer = cfg.settings.server or {};
  ownedWhy = {
    bind_address = "fixed to 127.0.0.1: SearXNG has no authentication, and this instance serves this machine only";
    port = "set by programs.pi.search.local.port";
    secret_key = "generated per user at the first start (0600, outside the world-readable store)";
  };

  script = action:
    pkgs.writeShellApplication {
      name = "pi-searx-${action}";
      runtimeInputs = [pkgs.coreutils pkgs.curl pkgs.gnugrep pkgs.util-linux];
      text =
        ''
          PI_SEARX_ACTION=${action}
          PI_SEARX_PORT=${toString cfg.port}
          PI_SEARX_TEMPLATE=${lib.escapeShellArg "${template}"}
          PI_SEARX_RUN=${lib.escapeShellArg (lib.getExe cfg.package)}
          PI_SEARX_REUSE=${
            if cfg.reuseExisting
            then "1"
            else "0"
          }
        ''
        + builtins.readFile ../../scripts/pi-searx.sh;
    };
  up = script "up";
  down = script "down";

  # The aliases' own command lines. `pi` is what ai-sandbox renders for the pi harness;
  # ai-sandbox renders its nono-only twin `pi_nono` too but exposes no render of it while
  # the isolation is on: it is the same line without the isolation wrapper's argv. The check
  # search-local pins both against ai-sandbox's aliases, so a change of that shape fails there
  # and, here, at evaluation.
  wrapped = scfg.enable && scfg.harnessProfiles ? pi;
  profile = scfg.harnessProfiles.pi;
  piCommand = scfg.render.command {
    command = "pi";
    inherit profile;
    alias = "pi";
  };
  isolationArgv = "exec ai-sandbox-run --nono-alias pi_nono --open-urls-profile ${profile} -- nono ";
  nonoCommand =
    if lib.hasInfix isolationArgv piCommand
    then builtins.replaceStrings [isolationArgv] ["exec nono "] piCommand
    else throw "pi-setup: programs.pi.search.local cannot derive the pi_nono command line from ai-sandbox's render.command (no '${isolationArgv}' in it); the alias shape changed";
  commands =
    lib.optionalAttrs wrapped ({pi = piCommand;}
      // lib.optionalAttrs isolationEnabled {pi_nono = nonoCommand;});

  # `<alias>-with-search`: pi-searx-up (a failure costs web search, never pi; off stdin, which
  # holds a prompt piped into pi), the URL (also a session variable, which a shell without Home
  # Manager's session file lacks), then the line. With reuseExisting off, a refused (or failed)
  # pi-searx-up leaves pi without the variable, so a server this module did not start is not
  # used by the back door.
  wrapper = alias: command:
    pkgs.writeShellApplication {
      name = "${alias}-with-search";
      runtimeInputs = [up scfg.package] ++ lib.optional (alias == "pi" && isolationEnabled) scfg.runPackage;
      text = ''
        ${
          if refuseForeign && isLocalUrl pcfg.search.searxUrl
          then ''
            if pi-searx-up </dev/null; then
              export PI_SEARX_URL=${lib.escapeShellArg pcfg.search.searxUrl}
            else
              unset PI_SEARX_URL
            fi''
          else ''
            pi-searx-up </dev/null || true
            ${lib.optionalString (pcfg.search.searxUrl != null) "export PI_SEARX_URL=${lib.escapeShellArg pcfg.search.searxUrl}"}''
        }
        ${command} "$@"
      '';
    };
in {
  options.programs.pi.search.local = {
    enable = lib.mkEnableOption ''
      an on-demand SearXNG on 127.0.0.1 for a web-search extension that reads `PI_SEARX_URL`,
      without NixOS or systemd: `pi-searx-up`, `pi-searx-down`, and the `pi`/`pi_nono` aliases
      starting it first. Sets `search.searxUrl` (mkDefault) to `http://127.0.0.1:<port>`
    '';

    port = lib.mkOption {
      type = lib.types.port;
      default = 8888;
      description = ''
        Loopback port. Whatever already answers `/healthz` there (a NixOS SearXNG, say) is
        reused instead of started, and logged as such; `pi-searx-down` leaves it alone (see
        `reuseExisting`).
      '';
    };

    reuseExisting = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether `pi-searx-up` reuses a server on the port that it did not start. That is a
        trust decision: pi sends its queries to whatever answers `/healthz` there and takes
        its results as they come, and on a machine with other users any of them may have
        bound the port first. The default is on because the NixOS SearXNG on the same port
        runs as another user and has to be reusable. Off, `pi-searx-up` fails when something
        it did not start answers (and says so), and the `pi` wrappers then start pi without
        `PI_SEARX_URL`, that is without search.
      '';
    };

    package = lib.mkPackageOption pkgs "searxng" {};

    settings = lib.mkOption {
      type = (pkgs.formats.yaml {}).type;
      default = {};
      example = lib.literalExpression ''
        {
          use_default_settings.engines.keep_only = [ "duckduckgo" "wikipedia" ];
          search.safe_search = 1;
        }
      '';
      description = ''
        SearXNG settings merged key by key over the base: `use_default_settings = true`
        (upstream's defaults, their engines included), `server.limiter = false`,
        `server.public_instance = false`, `search.formats = [ "html" "json" ]`. Engines are
        chosen through `use_default_settings.engines` (`keep_only`, `remove`) or an `engines`
        list. `search.formats` must keep `json`; `server.bind_address` (127.0.0.1),
        `server.port` (`port`) and `server.secret_key` (per user, at the first start) are the
        module's.
      '';
    };

    renderedSettings = lib.mkOption {
      type = (pkgs.formats.yaml {}).type;
      internal = true;
      readOnly = true;
      default = rendered;
      description = "The settings.yml template as data; its secret_key is the placeholder pi-searx-up replaces.";
    };

    commands = lib.mkOption {
      type = with lib.types; attrsOf str;
      internal = true;
      readOnly = true;
      default = commands;
      description = "The command line each wrapper runs after pi-searx-up, by alias.";
    };
  };

  config = lib.mkIf (pcfg.enable && cfg.enable) {
    programs.pi.search.searxUrl = lib.mkDefault url;

    warnings = lib.optional (!isLocalUrl pcfg.search.searxUrl) "pi-setup: programs.pi.search.local.enable is on but programs.pi.search.searxUrl is ${
      if pcfg.search.searxUrl == null
      then "null"
      else pcfg.search.searxUrl
    }, not ${url}: the local SearXNG starts but goes unused";

    assertions =
      lib.mapAttrsToList (k: why: {
        assertion = !(lib.isAttrs userServer && userServer ? ${k});
        message = "pi-setup: programs.pi.search.local.settings.server.${k} cannot be set: it is ${why}";
      })
      ownedWhy
      ++ [
        {
          assertion = lib.elem "json" (rendered.search.formats or []);
          message = "pi-setup: programs.pi.search.local.settings.search.formats must contain \"json\": pi's backend asks for format=json, which SearXNG refuses (403) otherwise";
        }
      ];

    home.packages = [up down] ++ lib.mapAttrsToList wrapper commands;

    # Over ai-sandbox's generated aliases (mkDefault), under a consumer's own extraAliases.
    programs.aiSandbox.extraAliases = lib.mapAttrs (alias: _: lib.mkOverride 900 "${alias}-with-search") commands;
  };
}
