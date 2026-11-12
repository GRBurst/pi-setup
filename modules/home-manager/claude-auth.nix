# pi's Claude auth: the `claude-auth` extension and, with `claudeAuth.setConfigDir`, pi's own
# Claude dir. The upstream claude-auth honours CLAUDE_CONFIG_DIR (its credentials file is
# <dir>/.credentials.json, else ~/.claude), so the wiring works with the default `package`. It is
# off by default: turning it on moves pi's Claude login to `dir` and needs `pi-claude-login` once.
# With it on, every Claude Code process inside a pi sandbox (claude-auth's `claude -p` refresh,
# and pi-claude-login) runs with CLAUDE_CONFIG_DIR = claudeAuth.dir, set on every profile
# extending the pi pack.
# The default dir lies under ~/.pi, which the nolabs-ai/pi pack already grants rw and no other
# pack does, so no grant is added; outside ~/.pi/agent, so pi never treats it as its own
# state. Never a session variable: unsandboxed `claude` keeps ~/.claude. No other profile may point
# CLAUDE_CONFIG_DIR at this dir (or under it); one with its own dir, such as the sandbox's
# ~/.claude-sandbox, is fine. nono expands $HOME in set_vars values.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.pi;
  auth = cfg.claudeAuth;
  scfg = config.programs.aiSandbox;
  isolationEnabled = scfg.enable && scfg.isolation.enable;

  # The one-time pi login into the pi Claude dir, INSIDE the pi sandbox: the dir is
  # agent-writable, so running Claude Code against it unsandboxed would execute agent-written
  # settings or hooks outside the sandbox. CLAUDE_CONFIG_DIR comes from the profile,
  # so the script does not restate it. Paste-code flow on stdin, no TTY needed.
  #
  # The cd is what keeps the profile's --allow-cwd from widening anything: run from ~, it
  # would grant the whole home directory, ~/.claude included. The pi Claude dir is already
  # granted (it lies under ~/.pi), so granting it as the cwd adds nothing.
  #
  # nono refuses to open the authorize URL (https://claude.com) in the browser: the pack's
  # open_urls allow-list names claude.ai, and a profile-level open_urls REPLACES the pack's
  # list instead of extending it (measured with `nono profile show`), so adding one origin
  # would mean restating and tracking the whole list. The URL is printed anyway; the hint
  # says so. With the namespace isolation on, the login also runs inside ai-sandbox-run,
  # whose xdg-open shim refuses every URL unless AI_SANDBOX_RELAX=browser, and even then the
  # relay allows only the same open_urls, so claude.com stays refused either way.
  loginEnabled = auth.login.enable && scfg.enable && scfg.harnessProfiles ? pi;
  login = pkgs.writeShellApplication {
    name = "pi-claude-login";
    runtimeInputs =
      [scfg.package pkgs.coreutils]
      ++ lib.optional isolationEnabled scfg.runPackage;
    text = ''
      echo "pi-claude-login: nono will refuse to open the browser (claude.com is not in its open_urls list); open the URL printed below by hand and paste the code back here." >&2
      mkdir -p "${auth.dir}"
      cd "${auth.dir}"
      ${scfg.render.command {
        command = "claude";
        profile = scfg.harnessProfiles.pi;
        tmpLeaf = "pi";
      }} auth login "$@"
    '';
  };

  expandHome = import ./expand-home.nix {inherit lib;} config.home.homeDirectory;

  # The pack nolabs-ai/pi grants ~/.pi read+write; a Claude dir elsewhere is granted here.
  dirInPiDir = auth.dir == "$HOME/.pi" || lib.hasPrefix "$HOME/.pi/" auth.dir;
in {
  options.programs.pi.claudeAuth = {
    enable =
      lib.mkEnableOption "the claude-auth extension (Claude subscription auth for pi) and, with `setConfigDir`, pi's own Claude dir"
      // {default = true;};

    dir = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.pi/claude";
      description = ''
        Claude Code's config dir inside every pi sandbox (CLAUDE_CONFIG_DIR; used only with `setConfigDir`): absolute, or
        starting with `$HOME/` (nono expands it). Under `$HOME/.pi` the pi pack's own grant covers
        it; anywhere else the dir is added to the grants of every profile extending the pack,
        read+write, so Claude Code can write its config, credentials and its own refresh lock.
      '';
    };

    login.enable =
      lib.mkEnableOption "`pi-claude-login`, the one-time `claude auth login` into `dir`, inside the pi sandbox (needs `setConfigDir`, the sandbox and its pi harness)"
      // {default = true;};

    setConfigDir = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether pi's Claude dir is wired: `CLAUDE_CONFIG_DIR = dir` on every profile extending the pi pack, the
        grant for a dir outside `$HOME/.pi`, its creation in activation, and `pi-claude-login`. The upstream
        claude-auth honours `CLAUDE_CONFIG_DIR`, so the extension reads `dir` too. Off by default: turning it on
        moves pi's Claude login to `dir`, so `pi-claude-login` must run once. Off: Claude Code and the extension
        keep `~/.claude`, and this module adds nothing of it to any sandbox profile.
      '';
    };

    credentialsFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default =
        if auth.setConfigDir
        then "${expandHome auth.dir}/.credentials.json"
        else "${config.home.homeDirectory}/.claude/.credentials.json";
      defaultText = lib.literalExpression ''"<dir with $HOME expanded>/.credentials.json" with setConfigDir, "<home>/.claude/.credentials.json" without'';
      description = "The absolute path of the Claude credentials file the extension reads (`dir` with `$HOME` expanded under `setConfigDir`, else `~/.claude`), for consumers outside the sandbox (e.g. a usage monitor).";
    };

    src = lib.mkOption {
      type = lib.types.path;
      internal = true;
      description = "The upstream pi-claude-auth source: the default of `package` and what the existence assertion probes.";
    };

    package = lib.mkOption {
      type = lib.types.path;
      default = auth.src;
      defaultText = lib.literalExpression "config.programs.pi.claudeAuth.src";
      description = ''
        The tree whose `src/` pi loads as the `claude-auth` extension: the upstream source by default;
        a consumer may point it at another build. Only the link moves: the existence assertion still probes
        `src`, and the key, the children policy and the input name stay.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && auth.enable) (lib.mkMerge [
    {
      # Under setConfigDir, credentialsFile is the absolute spelling of dir: only an absolute path or $HOME/ has one.
      assertions = [
        {
          assertion = lib.hasPrefix "/" auth.dir || lib.hasPrefix "$HOME/" auth.dir;
          message = "pi-setup: programs.pi.claudeAuth.dir must be an absolute path or start with $HOME/ (got '${auth.dir}'): under setConfigDir, credentialsFile is its absolute spelling";
        }
      ];

      # Seeds <agentDir>/auth.json from Claude Code's credentials and, on expiry, runs
      # `claude -p` so Claude Code refreshes them, under its own lock (with CLAUDE_CONFIG_DIR = `dir` inside the pi
      # sandboxes under `setConfigDir`). Loaded into children too: auth.json only shares the token; the billing header
      # (before_provider_request), the full Claude Code user-agent and the `claude -p` refresh
      # path are what bill a request to the plan, and a child with its own model runtime never
      # sees the parent's registration (without it children drained extra usage until Anthropic
      # answered 400 "out of extra usage"). Per-spawn auth.json seeding takes pi's auth.json lock.
      #
      # The whole src/ directory, not the repo root: its entry point is src/index.ts
      # (package.json `pi.extensions`), and pi discovers only <dir>/index.ts. src/ imports
      # nothing outside itself. The existence assertion probes the upstream input: probing a
      # built `package` would be import-from-derivation; a build that fails does so in
      # the package's build instead.
      programs.pi.extensions.claude-auth = {
        path = "${auth.package}/src";
        checkPath = "${auth.src}/src/index.ts";
        input = "pi-claude-auth";
        forChildren = true;
        description = "Uses Claude Code's OAuth credentials for the anthropic provider and refreshes them through `claude -p`.";
      };
    }

    # The config-dir wiring: only with `setConfigDir`.
    (lib.mkIf auth.setConfigDir {
      programs.aiSandbox.packDefaults."nolabs-ai/pi" = {
        setVars.CLAUDE_CONFIG_DIR = auth.dir;
        allow = lib.optional (!dirInPiDir) auth.dir;
      };
      home.packages = lib.optional loginEnabled login;

      # nono cannot canonicalise a path that does not exist and silently drops the grant for it: a
      # granted dir is created here (the login script's `mkdir -p` runs only if it is used, and pi
      # may start first). The default dir lies under ~/.pi, which the pack's grant covers.
      home.activation.piClaudeDir = lib.mkIf (!dirInPiDir && scfg.enable) (lib.hm.dag.entryAfter ["writeBoundary"] ''run install -d -m 0700 "${expandHome auth.dir}"'');
    })
  ]);
}
