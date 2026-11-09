# An on-demand, loopback-only SearXNG for a web-search extension that reads `PI_SEARX_URL`
# (`programs.pi.search.local`), for a machine without NixOS and without a systemd user
# session (a container); it works the same where both exist. No service and no unit:
# `pi-searx-up` starts it when nothing answers on the port (idempotent; state, pid, log and
# the per-user secret under `$XDG_STATE_HOME/pi-searx`, see ../../scripts/pi-searx.sh),
# `pi-searx-down` stops the instance it started, and the pre-start hook of ai-sandbox's pi
# harness (`programs.aiSandbox.harnesses.pi.preStart`) calls `pi-searx-up` before the
# sandboxed pi in `pi`, `pi_nono`, the variants and their `_nono` twins.
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

  # Sourced by every alias of the pi harness (pi, pi_nono, the variants and their twins),
  # outside the sandbox, before it starts (ai-sandbox's `harnesses.<name>.preStart`; POSIX
  # sh, stdin /dev/null, stdout on stderr, a failing command never stops pi). A failure of
  # pi-searx-up costs web search, never pi. It runs with TMPDIR unset: the alias gives pi a
  # per-CLI TMPDIR that the sandboxed pi can write, and the long-lived SearXNG daemon
  # (setsid) would inherit it. With reuseExisting off, a refused (or failed) pi-searx-up
  # leaves pi without the variable, so a server this module did not start is not used by
  # the back door. Store paths are absolute: the hook runs with the user's PATH.
  upCommand = "${lib.getExe' pkgs.coreutils "env"} -u TMPDIR ${lib.getExe up}";
  preStart =
    if refuseForeign && isLocalUrl pcfg.search.searxUrl
    then ''
      if ${upCommand}; then
        export PI_SEARX_URL=${lib.escapeShellArg pcfg.search.searxUrl}
      else
        unset PI_SEARX_URL
      fi
    ''
    else ''
      ${upCommand} || true
      ${lib.optionalString (pcfg.search.searxUrl != null) "export PI_SEARX_URL=${lib.escapeShellArg pcfg.search.searxUrl}"}
    '';
in {
  options.programs.pi.search.local = {
    enable = lib.mkEnableOption ''
      an on-demand SearXNG on 127.0.0.1 for a web-search extension that reads `PI_SEARX_URL`,
      without NixOS or systemd: `pi-searx-up`, `pi-searx-down`, and the pi aliases (`pi`,
      `pi_nono`, variants) starting it first through ai-sandbox's pre-start hook. Sets `search.searxUrl` (mkDefault) to `http://127.0.0.1:<port>`
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
        it did not start answers (and says so), and the pi aliases then start pi without
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

    home.packages = [up down];

    # Every generated alias of the pi harness sources it; with the sandbox or the harness off
    # there is no alias and no hook file.
    programs.aiSandbox.harnesses.pi.preStart = preStart;
  };
}
