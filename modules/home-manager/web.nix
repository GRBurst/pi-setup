# pi-web, the browser front end of pi (@jmfederico/pi-web), as a service of the sandbox module
# (`programs.aiSandbox.services.pi-web`, the sandbox module's services.nix): the same profile as pi's (the
# pi pack, so the Claude dir (with `claudeAuth.setConfigDir`) and the state file grant (with
# `settings.manage`) of ./claude-auth.nix and ./settings.nix reach
# it), the project root granted statically (a service has no --allow-cwd), its two sandboxed units,
# the proxy in front of the server and the data dir created at activation. Also `pi-sessions`, and
# the assertions of the pi module: Home Manager's own pi module excluded, the sandbox and pi on.
{
  config,
  lib,
  pkgs,
  ...
}: let
  p = config.programs.pi;
  cfg = p.web;
  scfg = config.programs.aiSandbox;
  home = config.home.homeDirectory;

  # Absolute, for what systemd, the activation line and the scripts read; the profile keeps the
  # `$HOME` spelling nono expands.
  dataDir = import ./expand-home.nix {inherit lib;} home cfg.dataDir;
  agentDir = "${home}/${p.agentDir}";

  piWebEnv = {
    PI_WEB_DATA_DIR = dataDir;
    PI_WEB_SESSIOND_SOCKET = "${dataDir}/sessiond.sock";
    # Shared with the terminal CLI on purpose: this is what makes a session
    # started in the browser resumable with `pi --session <id>`.
    PI_CODING_AGENT_DIR = agentDir;
  };

  # Drops settings.json package entries pointing at store paths that no longer
  # exist -- see the script for why they appear. Behaviour is covered by the
  # `agent-web-prune` flake check, not by eval assertions: it is a file
  # transformation, and the regression it guards against silently deleted every
  # entry.
  piWebPruneSettings = pkgs.writeShellApplication {
    name = "pi-web-prune-settings";
    runtimeInputs = [pkgs.jq pkgs.coreutils];
    text =
      ''
        export PI_WEB_SETTINGS=${lib.escapeShellArg "${agentDir}/settings.json"}
      ''
      + builtins.readFile ../../scripts/pi-web-prune-settings.sh;
  };

  piWebUnits = {
    pi-web-sessiond = {
      description = "PI WEB session daemon";
      exec = ["${cfg.package}/bin/pi-web-sessiond"];
      env = piWebEnv;
      extraService = {
        Type = "simple";
        ExecStartPre = "${piWebPruneSettings}/bin/pi-web-prune-settings";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # The backend unit: the sandbox module orders the proxy after it and makes it Want the
    # proxy (`backendUnit` below).
    pi-web-server = {
      description = "PI WEB HTTP/WebSocket server";
      exec = ["${cfg.package}/bin/pi-web-server"];
      extraUnit = {
        Requires = ["pi-web-sessiond.service"];
        After = ["pi-web-sessiond.service"];
      };
      env =
        piWebEnv
        // {
          # Loopback only. The proxy is the only listener that may face a
          # network, and this port is deliberately not in the firewall.
          PI_WEB_HOST = "127.0.0.1";
          # PI_WEB_PORT rather than PORT: PORT is an alias pi-web strips from
          # its agent children, so setting it would be both redundant and
          # misleading.
          PI_WEB_PORT = toString cfg.backendPort;
        };
      extraService = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };

  # Session continuity, the whole point of sharing PI_CODING_AGENT_DIR: list
  # what the browser (or the terminal) has started, newest first, so a session
  # can be picked up with `pi --session <id>`.
  piSessions = pkgs.writeShellApplication {
    name = "pi-sessions";
    runtimeInputs = [pkgs.jq pkgs.coreutils pkgs.findutils];
    text =
      ''
        export PI_SESSIONS_DIR=${lib.escapeShellArg "${agentDir}/sessions"}
      ''
      + builtins.readFile ../../scripts/pi-sessions.sh;
  };
in {
  options.programs.pi.web = {
    enable = lib.mkEnableOption "PI WEB (@jmfederico/pi-web) as a sandboxed user service behind a compressing proxy (listen address: `programs.aiSandbox.services.pi-web.proxy.listenAddress`)";

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 15432;
      description = ''
        Port the proxy listens on. This is the port a browser connects to.
        Never opened in a firewall by this module: pi-web has no authentication
        of its own and exposes an agent with full tool access, so it must be
        reachable over loopback (and a trusted VPN interface) only.
      '';
    };

    backendPort = lib.mkOption {
      type = lib.types.port;
      default = 15433;
      description = "Loopback port pi-web's HTTP/WebSocket server binds.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The pi-web package: the flake module (./flake-module.nix) defaults it to the
        flake's own build of pi-web, whose committed lockfile pins the published
        tarball together with its three `@earendil-works` peer dependencies and the
        `node-pty` native build.

        Upgrade with the `update.sh` next to that package. pi's own package manager cannot
        provision this: `pi install` passes `--legacy-peer-deps`, which skips
        the peers, and the standalone servers then fail with
        `ERR_MODULE_NOT_FOUND`.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.pi-web";
      description = ''
        PI_WEB_DATA_DIR: uploads, the sessiond owner file and socket, plugin state.
        Absolute, or starting with `$HOME`, which is the spelling the profile grants
        use (nono expands it) and which the units and the activation line expand.
      '';
    };
  };

  config = lib.mkMerge [
    {
      assertions =
        [
          {
            assertion = !(p.enable && (config.programs.pi-coding-agent.enable or false));
            message = ''
              pi-setup: programs.pi-coding-agent.enable must be false while programs.pi.enable is
              true: both own ${p.agentDir}/settings.json (Home Manager's module merges its own
              settings into it on every activation; programs.pi seeds it once and links it to a
              mutable state file).
            '';
          }
        ]
        ++ lib.optionals cfg.enable [
          {
            assertion = scfg.enable;
            message = ''
              pi-setup: programs.pi.web.enable requires programs.aiSandbox.enable. pi-web exposes an
              agent with full tool access to whatever reaches its port; the nono profile is the
              only boundary around it, so running it unsandboxed is not offered.
            '';
          }
          {
            assertion = p.enable;
            message = ''
              pi-setup: programs.pi.web.enable requires programs.pi.enable. The pi pack's grants of
              the pi-web profile (the state file with settings.manage, CLAUDE_CONFIG_DIR with
              claudeAuth.setConfigDir) and pi's settings come from
              the pi module; without it pi-web would run with neither.
            '';
          }
        ];
    }

    {
      # The service is always declared (like the sandbox module's presets) and on iff
      # `web.enable`: the same profile as the pi harness (the pi pack, the project root granted
      # statically, no --allow-cwd), its two sandboxed units, the proxy in front of the server
      # and the data dir created at activation.
      programs.aiSandbox.services.pi-web = {
        inherit (cfg) enable listenPort backendPort;
        # The unit that actually binds the backend port: the SERVER, not
        # "pi-web.service", which does not exist -- naming it left the proxy
        # ordered against nothing.
        backendUnit = "pi-web-server";
        dataDirs = [dataDir];
        profile = {
          pack = "nolabs-ai/pi";
          exclude = ["user_caches_linux"];
          allow = [
            scfg.projectsDir
            # PI_WEB_DATA_DIR: uploads, the sessiond owner file, plugin state.
            # The code itself is a read-only store path, so nothing else is needed.
            # Like the pi CLI profile, nothing under ~/.claude: Claude Code runs
            # as in the pi CLI (with `claudeAuth.setConfigDir`, the pi Claude dir).
            cfg.dataDir
          ];
          # pi-web-sessiond's socket (PI_WEB_SESSIOND_SOCKET) lives in its data dir.
          unixSocketSubtreeBind = [cfg.dataDir];
        };
        units = piWebUnits;
      };
    }

    (lib.mkIf cfg.enable {home.packages = [piSessions];})
  ];
}
