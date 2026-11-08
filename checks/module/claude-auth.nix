# pi's Claude dir, with `claudeAuth.setConfigDir` (off by default): every nolabs-ai/pi profile -- harness,
# variant, service -- runs Claude Code with CLAUDE_CONFIG_DIR = claudeAuth.dir and gets the state file grant
# (with `settings.manage`); the one-time
# pi-claude-login runs inside the pi sandbox; credentialsFile is the absolute credentials
# path for consumers outside the sandbox. The pi module alone (./lib.nix). Wired by
# ./default.nix as pi-setup-claude-auth.
{
  lib,
  pkgs,
  piLib,
}: let
  inherit (piLib) piFixtureWith piFailedWith piFailsWith;
  inherit (piLib.sandbox) mkAssertionCheck aiEmittedProfiles;
  home = "/tmp/ai-test";

  # A variant and a service on the pi pack next to the pi harness, so the per-profile row covers every kind of
  # profile that can extend it.
  piPackEverywhere = {
    programs.aiSandbox = {
      variants.pi_x = {
        harness = "pi";
        suffix = "x";
        allow = ["$HOME/x"];
      };
      services.svc = {
        enable = true;
        listenPort = 15500;
        backendPort = 15501;
        proxy.enable = false;
        profile.pack = "nolabs-ai/pi";
        units.svc = {
          description = "svc";
          exec = ["${pkgs.hello}/bin/hello"];
        };
      };
    };
  };

  # The rows below are about the config-dir wiring, which is off by default (the unpatched claude-auth reads ~/.claude):
  # their fixtures turn it on.
  withDir = extra:
    piFixtureWith {
      imports = [{programs.pi.claudeAuth.setConfigDir = true;} extra];
    };

  on = withDir piPackEverywhere;
  movedDir = withDir {
    imports = [piPackEverywhere];
    programs.pi.claudeAuth.dir = "$HOME/.config/pi-claude";
  };
  # `$HOME/.pi-claude` is not under `$HOME/.pi/`; one under it is.
  siblingDir = withDir {
    imports = [piPackEverywhere];
    programs.pi.claudeAuth.dir = "$HOME/.pi-claude";
  };
  insideDir = withDir {programs.pi.claudeAuth.dir = "$HOME/.pi/other/claude";};
  movedNoSandbox = withDir {
    programs.pi.claudeAuth.dir = "$HOME/.config/pi-claude";
    programs.aiSandbox.enable = false;
  };
  authOff = withDir {
    imports = [piPackEverywhere];
    programs.pi.claudeAuth.enable = false;
  };
  loginOff = withDir {programs.pi.claudeAuth.login.enable = false;};
  sandboxOff = withDir {programs.aiSandbox.enable = false;};
  harnessOff = withDir {programs.aiSandbox.harnesses.pi.enable = false;};
  noIsolation = withDir {programs.aiSandbox.isolation.enable = false;};
  # Planted: a non-pi profile that sets CLAUDE_CONFIG_DIR under pi's dir.
  plantedDir = withDir {
    programs.aiSandbox.harnesses.planted = {
      profileName = "planted";
      pack = "nolabs-ai/claude";
      setVars.CLAUDE_CONFIG_DIR = "$HOME/.pi/claude/sub";
    };
  };

  piProfiles = h: lib.filterAttrs (_: p: p.extends == ["nolabs-ai/pi"]) (aiEmittedProfiles h);
  otherProfiles = h: lib.filterAttrs (_: p: p.extends != ["nolabs-ai/pi"]) (aiEmittedProfiles h);
  setVars = p: p.environment.set_vars or {};

  # A Claude dir spelt with $HOME or ${HOME}, or with a trailing slash, is compared in its normal form.
  normDir = d: lib.removeSuffix "/" (lib.replaceStrings ["\${HOME}" "$HOME"] [home home] d);
  # d is pi's Claude dir or a dir under it.
  inPiDir = h: d: let
    p = normDir h.programs.pi.claudeAuth.dir;
    n = normDir d;
  in
    n == p || lib.hasPrefix "${p}/" n;
  # No profile of ps (of h) points CLAUDE_CONFIG_DIR at pi's Claude dir; a profile with its own dir is fine.
  noPiDirShared = h: ps:
    lib.all (p: let
      d = (setVars p).CLAUDE_CONFIG_DIR or null;
    in
      d == null || !(inPiDir h d))
    (lib.attrValues ps);

  # The Claude dir is inside the pack's ~/.pi grant, or granted read+write on the profile.
  dirGranted = h: p: let
    d = h.programs.pi.claudeAuth.dir;
  in
    d == "$HOME/.pi" || lib.hasPrefix "$HOME/.pi/" d || lib.elem d (p.filesystem.allow or []);

  # Over every nolabs-ai/pi profile of h: its Claude dir, the state file grant, the dir granted.
  p3 = h:
    lib.all (p:
      (setVars p).CLAUDE_CONFIG_DIR or null
      == h.programs.pi.claudeAuth.dir
      && lib.elem h.programs.pi.settings.stateGrant (p.filesystem.allow_file or [])
      && dirGranted h p)
    (lib.attrValues (piProfiles h));

  login = h: lib.findFirst (p: (p.name or "") == "pi-claude-login") null h.home.packages;
  loginText = h: (login h).text or "";
  has = needle: s: lib.hasInfix (builtins.unsafeDiscardStringContext needle) (builtins.unsafeDiscardStringContext s);
  piCommand = h:
    h.programs.aiSandbox.render.command {
      command = "claude";
      profile = h.programs.aiSandbox.harnessProfiles.pi;
      tmpLeaf = "pi";
    };
in
  mkAssertionCheck "pi-setup-claude-auth" [
    {
      # The selector must not silently match nothing: harness, variant and service.
      condition = lib.attrNames (piProfiles on) == ["pi-claude" "pi-claude-x" "svc"];
      message = "claude-auth: the fixture emits the pi harness, a pi variant and a pi-pack service profile";
    }
    {
      condition = on.programs.pi.claudeAuth.dir == "$HOME/.pi/claude" && p3 on;
      message = "claude-auth: every nolabs-ai/pi profile sets CLAUDE_CONFIG_DIR = claudeAuth.dir (default $HOME/.pi/claude) and grants the state file";
    }
    {
      # A dir outside ~/.pi is granted explicitly, on every pi profile and on no other; the
      # default dir (inside the pack's ~/.pi grant) adds no grant.
      condition = let
        d = "$HOME/.config/pi-claude";
        granted = p: lib.elem d (p.filesystem.allow or []);
      in
        (setVars (piProfiles movedDir).svc).CLAUDE_CONFIG_DIR or null
        == d
        && p3 movedDir
        && lib.all granted (lib.attrValues (piProfiles movedDir))
        && !(lib.any granted (lib.attrValues (otherProfiles movedDir)))
        && !(lib.any (p: lib.elem "$HOME/.pi/claude" (p.filesystem.allow or [])) (lib.attrValues (piProfiles on)));
      message = "claude-auth: CLAUDE_CONFIG_DIR follows claudeAuth.dir on every pi profile, and a dir outside ~/.pi is granted read+write on each of them and on no other profile";
    }
    {
      # A sibling of ~/.pi whose name starts with ".pi" is outside the pack's grant: it is
      # granted like any other dir (prefix test with the slash), a dir below ~/.pi is not.
      condition = let
        d = "$HOME/.pi-claude";
        granted = p: lib.elem d (p.filesystem.allow or []);
      in
        p3 siblingDir
        && lib.all granted (lib.attrValues (piProfiles siblingDir))
        && lib.all (p: !(lib.elem "$HOME/.pi/other/claude" (p.filesystem.allow or []))) (lib.attrValues (piProfiles insideDir))
        && p3 insideDir;
      message = "claude-auth: a dir named like ~/.pi but outside it ($HOME/.pi-claude) is granted on every pi profile, a dir below ~/.pi is not";
    }
    {
      # nono drops a grant for a path that does not exist: a granted dir is created in
      # activation (0700, absolute), and only then; the default dir lies under ~/.pi and adds nothing.
      condition = let
        a = h: h.home.activation.piClaudeDir or null;
      in
        (a movedDir).data
        == ''run install -d -m 0700 "${home}/.config/pi-claude"''
        && (a movedDir).after == ["writeBoundary"]
        && (a siblingDir).data == ''run install -d -m 0700 "${home}/.pi-claude"''
        && a on == null
        && a insideDir == null
        && a authOff == null
        && a movedNoSandbox == null;
      message = "claude-auth: a Claude dir outside ~/.pi is created in activation (install -d -m 0700, after writeBoundary) iff it is granted: not for the default or a dir below ~/.pi, nor with claudeAuth or the sandbox off";
    }
    {
      # credentialsFile is the absolute spelling of dir: a dir without one (relative, $XDG_*) is
      # refused, an absolute dir is kept as it is.
      condition =
        piFailsWith "pi-setup: programs.pi.claudeAuth.dir must be an absolute path or start with $HOME/" {programs.pi.claudeAuth.dir = "$XDG_CONFIG_HOME/pi-claude";}
        && piFailsWith "pi-setup: programs.pi.claudeAuth.dir must be an absolute path or start with $HOME/" {programs.pi.claudeAuth.dir = ".pi/claude";}
        && piFailedWith {programs.pi.claudeAuth.dir = "/var/lib/pi-claude";} == []
        && (withDir {programs.pi.claudeAuth.dir = "/var/lib/pi-claude";}).programs.pi.claudeAuth.credentialsFile == "/var/lib/pi-claude/.credentials.json"
        && piFailedWith {
          programs.pi.claudeAuth.enable = false;
          programs.pi.claudeAuth.dir = ".pi/claude";
        }
        == [];
      message = "claude-auth: a dir that is neither absolute nor under $HOME/ is refused (while claudeAuth is on); an absolute dir is accepted and is its own credentialsFile prefix";
    }
    {
      # Claude Code outside pi must not use pi's Claude dir: no other profile points CLAUDE_CONFIG_DIR at it (or under
      # it), and no session variable sets CLAUDE_CONFIG_DIR. A profile with its own dir (the sandbox's ~/.claude-sandbox) is fine.
      condition =
        noPiDirShared on (otherProfiles on)
        && !(on.home.sessionVariables ? CLAUDE_CONFIG_DIR);
      message = "claude-auth: no non-pi profile points CLAUDE_CONFIG_DIR at pi's Claude dir (or under it), and no session variable sets CLAUDE_CONFIG_DIR";
    }
    {
      # Negative case: the row above fails on a planted non-pi profile that sets CLAUDE_CONFIG_DIR under pi's dir.
      condition = !(noPiDirShared plantedDir (otherProfiles plantedDir)) && noPiDirShared on (otherProfiles on);
      message = "claude-auth: the pi-dir sharing check rejects a non-pi profile that sets CLAUDE_CONFIG_DIR under pi's dir, and accepts the sandbox's own dir";
    }
    {
      condition =
        noPiDirShared authOff (aiEmittedProfiles authOff)
        && login authOff == null;
      message = "claude-auth: with claudeAuth.enable = false no profile points CLAUDE_CONFIG_DIR at pi's Claude dir and there is no pi-claude-login";
    }
    {
      condition =
        login on
        != null
        && login loginOff == null
        && login sandboxOff == null
        && login harnessOff == null;
      message = "claude-auth: pi-claude-login is installed iff login.enable, the sandbox and the pi harness are on";
    }
    {
      # Inside the pi sandbox through render.command, from the Claude dir as cwd (so
      # --allow-cwd adds nothing); the config dir comes from the profile, never the script.
      condition = let
        t = loginText on;
      in
        has ''mkdir -p "$HOME/.pi/claude"'' t
        && has ''cd "$HOME/.pi/claude"'' t
        && has "${piCommand on} auth login \"$@\"" t
        && has "exec ai-sandbox-run " t
        && has "${on.programs.aiSandbox.runPackage}/bin" t
        && !(lib.hasInfix "CLAUDE_CONFIG_DIR" t)
        && !(lib.hasInfix "CLAUDE_SECURESTORAGE_CONFIG_DIR" t);
      message = "claude-auth: pi-claude-login runs `claude auth login` through render.command in the pi profile, from the Claude dir";
    }
    {
      condition = let
        t = loginText noIsolation;
      in
        has "${piCommand noIsolation} auth login \"$@\"" t
        && !(lib.hasInfix "ai-sandbox-run" t);
      message = "claude-auth: with the isolation off pi-claude-login runs nono directly";
    }
    {
      condition =
        on.programs.pi.claudeAuth.credentialsFile
        == "${home}/.pi/claude/.credentials.json"
        && movedDir.programs.pi.claudeAuth.credentialsFile == "${home}/.config/pi-claude/.credentials.json";
      message = "claude-auth: credentialsFile is <dir>/.credentials.json with $HOME expanded";
    }
    {
      # The default: the config-dir wiring is off (the unpatched claude-auth reads and locks ~/.claude; a Claude dir it
      # never reads would only mislead). No profile gets the variable or a grant, there is no login script and no Claude
      # dir activation even for a dir outside ~/.pi, the credentials file is ~/.claude's, and the extension stays.
      condition = let
        d = piFixtureWith piPackEverywhere;
        far = piFixtureWith {programs.pi.claudeAuth.dir = "$HOME/.config/pi-claude";};
      in
        !d.programs.pi.claudeAuth.setConfigDir
        && noPiDirShared d (aiEmittedProfiles d)
        && login d == null
        && !(far.home.activation ? piClaudeDir)
        && !(lib.any (p: lib.elem "$HOME/.config/pi-claude" (p.filesystem.allow or [])) (lib.attrValues (aiEmittedProfiles far)))
        && d.programs.pi.claudeAuth.credentialsFile == "${home}/.claude/.credentials.json"
        && far.programs.pi.claudeAuth.credentialsFile == "${home}/.claude/.credentials.json"
        && d.programs.pi.extensions ? claude-auth;
      message = "claude-auth: with setConfigDir off (the default) no profile points CLAUDE_CONFIG_DIR at pi's Claude dir or grants a Claude dir, there is no pi-claude-login or Claude dir activation, credentialsFile is under ~/.claude and the extension stays";
    }
    {
      # What this module could add to the sandbox's pi pack by default is nothing: with the settings file left to pi as well, the
      # pack's defaults of the pi module are empty, so a package built from this module ships no sandbox profile.
      condition = let
        d = piFixtureWith {programs.pi.settings.manage = false;};
        pack = d.programs.aiSandbox.packDefaults."nolabs-ai/pi" or {};
      in
        lib.filterAttrs (_: v: v != [] && v != {} && v != null) pack == {};
      message = "claude-auth: with setConfigDir and settings.manage off the module adds nothing to the nolabs-ai/pi pack";
    }
    {
      # setConfigDir on is the whole wiring: variable and grant on every pi-pack profile, the login script, the credentials
      # file under the dir; the dir assertion applies with it on as well.
      condition =
        on.programs.pi.claudeAuth.setConfigDir
        && p3 on
        && login on != null
        && piFailsWith "pi-setup: programs.pi.claudeAuth.dir must be an absolute path or start with $HOME/" {
          imports = [{programs.pi.claudeAuth.setConfigDir = true;}];
          programs.pi.claudeAuth.dir = ".pi/claude";
        };
      message = "claude-auth: with setConfigDir on the Claude dir is wired on every pi profile, pi-claude-login exists and the dir assertion still holds";
    }
    {
      # The warning of setConfigDir with the unpatched upstream (package = src): the profiles would set CLAUDE_CONFIG_DIR for
      # an extension that reads ~/.claude. Neither the default (wiring off) nor a package of its own (a patched build) warns.
      condition = let
        warned = d: lib.any (lib.hasInfix "claudeAuth.package is the unpatched upstream") d.warnings;
      in
        warned (piFixtureWith {programs.pi.claudeAuth.setConfigDir = true;})
        && !(warned (piFixtureWith {}))
        && !(warned (piFixtureWith {
          programs.pi.claudeAuth = {
            setConfigDir = true;
            package = "/nonexistent/patched";
          };
        }));
      message = "claude-auth: setConfigDir with the unpatched package warns; the default and a package of its own do not";
    }
  ]
