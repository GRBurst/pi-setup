# pi-web as `programs.pi.web`: the module defines the service `pi-web` of the sandbox
# module — units sessiond/server (and the proxy the sandbox module generates), their
# environment, the settings prune `ExecStartPre`, `pi-sessions`, the profile of the pi pack with
# its two extra grants — and asserts the sandbox, pi and the absence of programs.pi-coding-agent. The pi module alone, no host
# (./lib.nix). Wired by ./default.nix as pi-setup-web.
{
  lib,
  piLib,
}: let
  inherit (piLib) piFixtureWith piFailedWith piFailsWith;
  inherit (piLib.sandbox) mkAssertionCheck aiEmittedProfiles;
  home = "/tmp/ai-test";

  on = piFixtureWith {programs.pi.web.enable = true;};
  # The Claude dir is wired only with `claudeAuth.setConfigDir` (off by default): the profile row turns it on.
  onDir = piFixtureWith {
    programs.pi.web.enable = true;
    programs.pi.claudeAuth.setConfigDir = true;
  };
  off = piFixtureWith {};
  mediated = piFixtureWith {
    programs.pi.web.enable = true;
    programs.aiSandbox.unixMediation.enable = true;
  };
  moved = piFixtureWith {
    programs.pi.web = {
      enable = true;
      listenPort = 15600;
      backendPort = 15601;
      dataDir = "$HOME/.local/share/pi-web";
    };
    programs.pi.agentDir = ".pi/other";
  };
  noIsolation = piFixtureWith {
    programs.pi.web.enable = true;
    programs.aiSandbox.isolation.enable = false;
  };

  unit = h: n: h.systemd.user.services.${n};
  execOf = h: n: let
    v = (unit h n).Service.ExecStart;
  in
    if lib.isList v
    then lib.concatStringsSep " " v
    else v;
  envOf = h: n:
    lib.listToAttrs (map (kv: let
        p = lib.splitString "=" kv;
      in {
        name = lib.head p;
        value = lib.concatStringsSep "=" (lib.tail p);
      })
      (unit h n).Service.Environment);
  # The module's own entries (PATH, TMPDIR, AI_SANDBOX_RELAX) are the sandbox module's, tested there.
  piWebEnv = h: n: removeAttrs (envOf h n) ["PATH" "TMPDIR" "AI_SANDBOX_RELAX"];

  contains = needle: text: let
    t = builtins.unsafeDiscardStringContext text;
  in
    builtins.replaceStrings [needle] [""] t != t;

  pkg = h: h.programs.pi.web.package;
  piWebUnits = ["pi-web-proxy" "pi-web-server" "pi-web-sessiond"];
  hasPkg = h: n: lib.any (p: (p.name or "") == n) h.home.packages;
  piSessions = h: lib.findFirst (p: (p.name or "") == "pi-sessions") {} h.home.packages;
  profile = h: (aiEmittedProfiles h).pi-web;
in
  mkAssertionCheck "pi-setup-web" [
    {
      condition =
        on.programs.aiSandbox.serviceUnits
        == {pi-web = piWebUnits;}
        && lib.all (n: on.systemd.user.services ? ${n}) piWebUnits
        && on.xdg.configFile ? "agent-web/pi-web/Caddyfile";
      message = "web: enabled, pi-web is a service of three units: sessiond, server and the proxy in front of it";
    }
    {
      condition =
        off.programs.aiSandbox.serviceUnits
        == {}
        && !(lib.any (n: off.systemd.user.services ? ${n}) piWebUnits)
        && !(aiEmittedProfiles off ? pi-web)
        && !(hasPkg off "pi-sessions")
        && !(off.home.activation ? agentWebDirs);
      message = "web: disabled (the default), no unit, profile, pi-sessions or data dir exists";
    }
    {
      condition =
        lib.hasSuffix " -- ${pkg on}/bin/pi-web-sessiond" (execOf on "pi-web-sessiond")
        && lib.hasSuffix " -- ${pkg on}/bin/pi-web-server" (execOf on "pi-web-server")
        && (unit on "pi-web-server").Unit.Requires == ["pi-web-sessiond.service"]
        && (unit on "pi-web-server").Unit.After == ["pi-web-sessiond.service"]
        && (unit on "pi-web-server").Unit.Wants == ["pi-web-proxy.service"]
        && !((unit on "pi-web-sessiond").Unit ? Requires);
      message = "web: the units run the package's two binaries inside nono; the server needs sessiond and wants the proxy";
    }
    {
      # The units: the namespace wrapper, the declared work tree and the strict broker
      # path, for both sandboxed units; the proxy is no agent and is not wrapped.
      condition =
        lib.all (n: let
          e = execOf on n;
        in
          lib.hasPrefix "${on.programs.aiSandbox.runPackage}/bin/ai-sandbox-run -- " e
          && contains " run --profile pi-web --workdir ${home}/projects --strict-broker-path " e)
        ["pi-web-sessiond" "pi-web-server"]
        && !(contains "nono" (execOf on "pi-web-proxy"));
      message = "web: both sandboxed units start nono inside ai-sandbox-run with the profile, --workdir and --strict-broker-path; the proxy is not wrapped";
    }
    {
      condition = lib.hasPrefix "/nix/store/" (execOf noIsolation "pi-web-server") && contains "/bin/nono run --profile pi-web " (execOf noIsolation "pi-web-server") && !(contains "ai-sandbox-run" (execOf noIsolation "pi-web-server"));
      message = "web: with isolation.enable = false the units start nono directly";
    }
    {
      # The state the browser and the terminal share: one data dir, one agent dir, absolute.
      condition = let
        shared = {
          PI_WEB_DATA_DIR = "${home}/.pi-web";
          PI_WEB_SESSIOND_SOCKET = "${home}/.pi-web/sessiond.sock";
          PI_CODING_AGENT_DIR = "${home}/.pi/agent";
        };
      in
        piWebEnv on "pi-web-sessiond"
        == shared
        && piWebEnv on "pi-web-server"
        == shared
        // {
          # Loopback only: the proxy is the one listener that may face a network.
          PI_WEB_HOST = "127.0.0.1";
          PI_WEB_PORT = "15433";
        };
      message = "web: sessiond and server share the data dir, the socket and pi's agent dir; the server binds loopback on the backend port";
    }
    {
      condition = let
        shared = {
          PI_WEB_DATA_DIR = "${home}/.local/share/pi-web";
          PI_WEB_SESSIOND_SOCKET = "${home}/.local/share/pi-web/sessiond.sock";
          PI_CODING_AGENT_DIR = "${home}/.pi/other";
        };
      in
        piWebEnv moved "pi-web-sessiond"
        == shared
        && piWebEnv moved "pi-web-server"
        == shared
        // {
          PI_WEB_HOST = "127.0.0.1";
          PI_WEB_PORT = "15601";
        }
        && moved.programs.aiSandbox.services.pi-web.listenPort == 15600
        && contains ":15600 {" moved.xdg.configFile."agent-web/pi-web/Caddyfile".text
        && contains "reverse_proxy 127.0.0.1:15601 " moved.xdg.configFile."agent-web/pi-web/Caddyfile".text;
      message = "web: dataDir, agentDir and the ports flow into the units' environment and the proxy";
    }
    {
      # The prune runs before sessiond only, on the settings file of pi's agent dir (its path is
      # baked into the script, so it moves with agentDir).
      condition = let
        pre = h: (unit h "pi-web-sessiond").Service.ExecStartPre;
      in
        lib.hasPrefix "/nix/store/" (pre on)
        && lib.hasSuffix "/bin/pi-web-prune-settings" (pre on)
        && pre moved != pre on
        && !((unit on "pi-web-server").Service ? ExecStartPre);
      message = "web: pi-web-prune-settings is sessiond's ExecStartPre alone, and follows agentDir";
    }
    {
      condition = let
        s = piSessions on;
      in
        contains "export PI_SESSIONS_DIR=${home}/.pi/agent/sessions" (s.text or "")
        && contains "export PI_SESSIONS_DIR=${home}/.pi/other/sessions" ((piSessions moved).text or "");
      message = "web: pi-sessions lists the sessions of pi's agent dir";
    }
    {
      # The data dir exists before nono sees the grant (a grant on a missing path is dropped
      # silently), created absolute and 0700.
      condition =
        on.home.activation.agentWebDirs.data
        == ''run install -d -m 0700 "${home}/.pi-web"''
        && moved.home.activation.agentWebDirs.data == ''run install -d -m 0700 "${home}/.local/share/pi-web"'';
      message = "web: the data dir is created absolute at 0700 in activation (agentWebDirs)";
    }
    {
      # The pi-web profile: the pi pack, the Claude dir and the state file grant, and the
      # module's own grants, spelled as nono expands them.
      condition = let
        p = profile onDir;
      in
        p.extends
        == ["nolabs-ai/pi"]
        && ((p.environment.set_vars or {}).CLAUDE_CONFIG_DIR or null) == onDir.programs.pi.claudeAuth.dir
        && lib.elem onDir.programs.pi.settings.stateGrant (p.filesystem.allow_file or [])
        && lib.elem "$HOME/projects" p.filesystem.allow
        && lib.elem "$HOME/.pi-web" p.filesystem.allow
        && p.network.listen_port == [15433]
        && !(p.filesystem ? unix_socket_subtree_bind);
      message = "web: the pi-web profile extends the pi pack with CLAUDE_CONFIG_DIR, the state file, the projects dir and the data dir, and listens on the backend port";
    }
    {
      condition = let
        p = profile mediated;
        m = profile moved;
      in
        p.filesystem.unix_socket_subtree_bind
        == ["$TMPDIR" "$HOME/.pi-web"]
        && lib.elem "$HOME/.local/share/pi-web" m.filesystem.allow
        && !(lib.elem "$HOME/.pi-web" m.filesystem.allow)
        && m.network.listen_port == [15601];
      message = "web: with mediation the data dir is bindable (the sessiond socket lives in it); dataDir and backendPort move the grants";
    }
    {
      condition = on.programs.aiSandbox.harnessProfiles ? pi && !(on.programs.aiSandbox.harnessProfiles ? pi-web) && !(on.home.shellAliases ? pi-web);
      message = "web: pi-web is a service profile, not a harness: no alias, no --allow-cwd";
    }
    {
      condition = piFailedWith {programs.pi.web.enable = true;} == [] && piFailedWith {} == [];
      message = "web: the healthy configuration, enabled and disabled, fails no assertion";
    }
    {
      # Sandbox off: the module's own assertion fires next to the sandbox module's.
      condition = let
        f = piFailedWith {
          programs.pi.web.enable = true;
          programs.aiSandbox.enable = false;
        };
      in
        lib.any (lib.hasPrefix "pi-setup: programs.pi.web.enable requires programs.aiSandbox.enable") f
        && lib.all (m: lib.hasPrefix "pi-setup: " m || lib.hasPrefix "ai-sandbox: " m) f;
      message = "web: pi-web without programs.aiSandbox.enable must fail the module's assertion";
    }
    {
      # Home Manager's own programs.pi-coding-agent also manages settings.json.
      condition =
        piFailsWith "pi-setup: programs.pi-coding-agent.enable must be false" {programs.pi-coding-agent.enable = true;}
        && piFailedWith {
          programs.pi.enable = false;
          programs.pi-coding-agent.enable = true;
        }
        == [];
      message = "web: programs.pi-coding-agent next to programs.pi must fail, and only while programs.pi is on";
    }
    {
      # The profile's pack grants (state file, CLAUDE_CONFIG_DIR) and pi's settings come from the
      # pi module: a pi-web without it would run with neither, silently.
      condition = piFailsWith "pi-setup: programs.pi.web.enable requires programs.pi.enable" {
        programs.pi.enable = false;
        programs.pi.web.enable = true;
      };
      message = "web: programs.pi.web.enable without programs.pi.enable must fail, with exactly that assertion";
    }
  ]
