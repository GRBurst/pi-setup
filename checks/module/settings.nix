# pi's settings file: seed, out-of-store link, reclaim, the state
# file grant on the pi pack, and `settings.manage` (off: pi owns the file, nothing is linked,
# seeded, reclaimed or granted). The pi module alone (./lib.nix). Wired by ./default.nix as
# pi-setup-settings.
{
  lib,
  pkgs,
  piLib,
}: let
  inherit (piLib) piFixtureWith piFailedWith piFailsWith bridge piEconomicsStub;
  inherit (piLib.sandbox) mkAssertionCheck aiEmittedProfiles;
  home = "/tmp/ai-test";
  state = "${home}/.local/state/pi/settings.json";

  on = piFixtureWith {};
  off = piFixtureWith {programs.aiSandbox.enable = false;};
  seeded = piFixtureWith {programs.pi.settings.seed.defaultThinkingLevel = "high";};
  moved = piFixtureWith {
    programs.pi = {
      agentDir = ".config/pi-agent";
      settings.stateFile = ".config/pi/settings.json";
    };
  };
  disabled = piFixtureWith {programs.pi.enable = false;};
  withPackage = piFixtureWith {programs.pi.package = pkgs.cowsay;};
  unmanaged = piFixtureWith {programs.pi.settings.manage = false;};
  # The economics bridge reads the state file; here against a stub of the `programs.piEconomics` options.
  bridgedOptions = {imports = [bridge piEconomicsStub];};

  act = h: h.home.activation;
  # The seed file the module must install: same name, same text => same store path.
  seedOf = seed: toString (pkgs.writeText "pi-settings-seed.json" (builtins.toJSON seed));
  # hasInfix over strings with store paths (lib.hasInfix refuses string context).
  has = needle: s: lib.hasInfix (builtins.unsafeDiscardStringContext needle) (builtins.unsafeDiscardStringContext s);
  linkOf = h: path: (h.lib.file.mkOutOfStoreSymlink path).outPath;
in
  mkAssertionCheck "pi-setup-settings" [
    {
      # The seed: written once (guarded by -e), from a store file named pi-settings-seed.json
      # whose text is toJSON of `settings.seed`; the default seed is {packages = [];}.
      condition = let
        s = (act on).piSettingsSeed.data;
      in
        on.programs.pi.settings.seed
        == {packages = [];}
        && has ''if [ ! -e "${state}" ]; then'' s
        && has ''run install -m 0644 ${seedOf {packages = [];}} "${state}"'' s;
      message = "settings: the seed is toJSON settings.seed in pi-settings-seed.json, installed once into the state file";
    }
    {
      # Seed keys merge leaf by leaf: a consumer's key adds to the default packages = [].
      condition =
        has (seedOf {
          packages = [];
          defaultThinkingLevel = "high";
        })
        (act seeded).piSettingsSeed.data;
      message = "settings: a seed key set by a consumer merges with the default seed";
    }
    {
      # <agentDir>/settings.json is an out-of-store link to the state file (pi and nono write it).
      condition =
        on.home.file.".pi/agent/settings.json".source.outPath
        == linkOf on state
        && moved.home.file.".config/pi-agent/settings.json".source.outPath
        == linkOf moved "${home}/.config/pi/settings.json";
      message = "settings: <agentDir>/settings.json is an out-of-store link to settings.stateFile";
    }
    {
      # DAG: the seed before linkGeneration, the reclaim before checkLinkTargets; the reclaim
      # adopts pi's regular file (mv, never rm).
      condition = let
        a = act on;
      in
        a.piSettingsSeed.before
        == ["linkGeneration"]
        && a.piSettingsSeed.after == []
        && a.piSettingsReclaim.before == ["checkLinkTargets"]
        && a.piSettingsReclaim.after == []
        && has ''run mv -f "${home}/.pi/agent/settings.json" "${state}"'' a.piSettingsReclaim.data
        && has ''run mv -f "${home}/.config/pi-agent/settings.json" "${home}/.config/pi/settings.json"'' (act moved).piSettingsReclaim.data;
      message = "settings: piSettingsSeed before linkGeneration, piSettingsReclaim before checkLinkTargets";
    }
    {
      # The reclaim defaults to the sandbox's switch; the seed does not depend on it.
      condition =
        (act off) ? piSettingsSeed
        && !((act off) ? piSettingsReclaim)
        && !off.programs.pi.settings.reclaim.enable
        && (piFixtureWith {
          programs.aiSandbox.enable = false;
          programs.pi.settings.reclaim.enable = true;
        }).home.activation ? piSettingsReclaim;
      message = "settings: piSettingsReclaim is absent with the sandbox off unless reclaim.enable is set";
    }
    {
      # The state file grant on the pi pack, in $XDG_STATE_HOME spelling under
      # .local/state, $HOME-relative otherwise; it reaches the emitted pi profile.
      condition =
        on.programs.pi.settings.stateGrant
        == "$XDG_STATE_HOME/pi/settings.json"
        && on.programs.aiSandbox.packDefaults."nolabs-ai/pi".allowFile == ["$XDG_STATE_HOME/pi/settings.json"]
        && lib.elem "$XDG_STATE_HOME/pi/settings.json" (aiEmittedProfiles on).${on.programs.aiSandbox.harnessProfiles.pi}.filesystem.allow_file
        && moved.programs.pi.settings.stateGrant == "$HOME/.config/pi/settings.json";
      message = "settings: the pi pack grants the state file (settings.stateGrant)";
    }
    {
      # Off means nothing: no link, no activation, no pack delta. `package` is installed only
      # when set (a consumer may install pi itself).
      condition =
        !(disabled.home.file ? ".pi/agent/settings.json")
        && !((act disabled) ? piSettingsSeed)
        && !((act disabled) ? piSettingsReclaim)
        && !(disabled.programs.aiSandbox.packDefaults ? "nolabs-ai/pi")
        && on.programs.pi.package == null
        && !(lib.elem pkgs.cowsay on.home.packages)
        && lib.elem pkgs.cowsay withPackage.home.packages;
      message = "settings: programs.pi off adds nothing; package is installed only when non-null";
    }
    {
      # `manage = false` (default true): pi owns <agentDir>/settings.json, so no link, no seed and
      # no reclaim activation, and no state file grant in any pi-pack profile; the seed option keeps
      # its default (a consumer may still read it).
      condition =
        on.programs.pi.settings.manage
        && !unmanaged.programs.pi.settings.manage
        && !(unmanaged.home.file ? ".pi/agent/settings.json")
        && !((act unmanaged) ? piSettingsSeed)
        && !((act unmanaged) ? piSettingsReclaim)
        && (unmanaged.programs.aiSandbox.packDefaults."nolabs-ai/pi".allowFile or []) == []
        && !(lib.elem "$XDG_STATE_HOME/pi/settings.json" (aiEmittedProfiles unmanaged).${unmanaged.programs.aiSandbox.harnessProfiles.pi}.filesystem.allow_file)
        && unmanaged.programs.pi.settings.seed == {packages = [];};
      message = "settings: settings.manage = false links, seeds, reclaims and grants nothing";
    }
    {
      # The economics bridge edits the state file, so it refuses `manage = false`; the default stays quiet.
      condition =
        piFailsWith "pi-setup: programs.pi.settings.manage = false leaves no state file for the economics bridge" {
          imports = [bridgedOptions];
          programs.pi.settings.manage = false;
        }
        && piFailedWith bridgedOptions == [];
      message = "settings: the economics bridge asserts settings.manage";
    }
  ]
