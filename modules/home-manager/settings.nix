# pi's settings file. pi reads ~/.pi (`agentDir`), not XDG, and `<agentDir>/settings.json` has
# two writers besides Home Manager:
#
#   1. nono's pack wiring -- nolabs-ai/pi's package.json declares
#      {"type":"json_array_append","file":"$HOME/.pi/agent/settings.json",
#       "path":"packages"} and appends its own entry on every pack install.
#   2. pi itself, via /settings and trackingId.
#
# A read-only store symlink loses to both (the live file is already a clobbered regular file,
# which would abort the next switch on HM's clobber check). So HM owns the *location* (an
# out-of-store link to `settings.stateFile`) and seeds the initial content once, but the file
# itself stays mutable. Mutable, outside the store and outside the config tree: pointing it
# into a flake would hand a sandboxed agent write access inside the configuration.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.pi;
  homeDir = config.home.homeDirectory;
  statePath = "${homeDir}/${cfg.settings.stateFile}";
  linkPath = "${homeDir}/${cfg.agentDir}/settings.json";

  # The JSON is a store file installed by activation; checks compare its store path with
  # `writeText "pi-settings-seed.json" (toJSON seed)`, i.e. the seeded content itself.
  seedFile = pkgs.writeText "pi-settings-seed.json" (builtins.toJSON cfg.settings.seed);

  jsonType = (pkgs.formats.json {}).type;
in {
  options.programs.pi = {
    enable = lib.mkEnableOption "pi (the coding agent): its settings file, extensions and services";

    package = lib.mkOption {
      type = with lib.types; nullOr package;
      default = null;
      description = "The pi package, installed when non-null (a consumer may install pi itself).";
    };

    agentDir = lib.mkOption {
      type = lib.types.str;
      default = ".pi/agent";
      description = "pi's agent dir, relative to the home directory (PI_CODING_AGENT_DIR).";
    };

    settings = {
      manage = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether this module manages `<agentDir>/settings.json`: the out-of-store link to
          `settings.stateFile`, the seed (`piSettingsSeed`), the reclaim (`piSettingsReclaim`) and
          the state file grant on the pi pack. `false` leaves the file to pi alone: none of the four
          exists, and the economics bridge, which edits the state file, refuses it. `settings.seed`
          keeps its default and stays readable.
        '';
      };

      seed = lib.mkOption {
        type = lib.types.attrsOf jsonType;
        default = {};
        defaultText = lib.literalExpression "{packages = [];}";
        description = ''
          Initial content of `<agentDir>/settings.json`, merged key by key (a consumer's key adds
          to the default `packages = []`). Written **once**, only if `settings.stateFile` does
          not exist yet; pi and nono both write the file at runtime, so it is deliberately not
          kept in sync afterwards. To apply a changed seed to an existing machine, delete the
          state file and re-run the switch.
        '';
      };

      stateFile = lib.mkOption {
        type = lib.types.str;
        default = ".local/state/pi/settings.json";
        description = "The mutable file `<agentDir>/settings.json` links to, relative to the home directory.";
      };

      stateGrant = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default =
          if lib.hasPrefix ".local/state/" cfg.settings.stateFile
          then "$XDG_STATE_HOME/${lib.removePrefix ".local/state/" cfg.settings.stateFile}"
          else "$HOME/${cfg.settings.stateFile}";
        defaultText = lib.literalMD "`settings.stateFile` in the spelling nono expands";
        description = ''
          The state file as granted on the pi pack (`packDefaults."nolabs-ai/pi".allowFile`):
          Landlock resolves the settings symlink to its target, so the pack's ~/.pi grant does
          not cover pi's own writes to it.
        '';
      };

      reclaim.enable = lib.mkOption {
        type = lib.types.bool;
        default = config.programs.aiSandbox.enable;
        defaultText = lib.literalExpression "config.programs.aiSandbox.enable";
        description = ''
          Activation `piSettingsReclaim`: adopt a regular file pi wrote over the settings link
          into the state file, before Home Manager's clobber check.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      programs.pi.settings.seed = {
        # Empty, but kept so the seed has the shape pi and nono's `json_array_append` pack wiring
        # expect.
        packages = lib.mkDefault [];
      };

      home.packages = lib.optional (cfg.package != null) cfg.package;
    }

    # The settings file itself (`settings.manage`): the link, the state file grant, the seed and
    # the reclaim.
    (lib.mkIf cfg.settings.manage {
      home.file."${cfg.agentDir}/settings.json".source =
        config.lib.file.mkOutOfStoreSymlink statePath;

      programs.aiSandbox.packDefaults."nolabs-ai/pi".allowFile = [cfg.settings.stateGrant];

      home.activation =
        {
          # Seed once, then never touch it again -- pi and nono own the content
          # from here on. `if`, not `[ ... ] && ...`: the latter trips activation's
          # `set -e` when the test is false.
          # `install` rather than a heredoc redirect: activation's `run` only
          # echoes under DRY_RUN, but a `> "$f"` redirect is performed by the
          # shell regardless. That would leave an empty file behind on
          # `switch -n`, and the `-e` guard would then make the real switch skip
          # seeding entirely.
          piSettingsSeed = lib.hm.dag.entryBefore ["linkGeneration"] ''
            if [ ! -e "${statePath}" ]; then
              run mkdir -p "$(dirname "${statePath}")"
              run install -m 0644 ${seedFile} "${statePath}"
            fi
          '';
        }
        // lib.optionalAttrs cfg.settings.reclaim.enable {
          # pi -- and nono's `json_array_append` pack wiring -- write
          # <agentDir>/settings.json by atomic rename, which REPLACES the
          # out-of-store symlink with a regular file. HM's clobber check
          # then aborts the switch (observed 2026-09-22).
          #
          # Same shape as the sandbox's nonoProfileReclaim, opposite ownership. Nix owns the
          # nono profiles, so that reclaim discards nono's rewrite. pi owns THIS
          # content, so this one ADOPTS the rewrite: the regular file is what pi
          # last wrote, i.e. the newest state, and it becomes the state file the
          # symlink points at. Deleting it would silently lose pi's settings.
          piSettingsReclaim = lib.hm.dag.entryBefore ["checkLinkTargets"] ''
            if [ -e "${linkPath}" ] && [ ! -L "${linkPath}" ]; then
              warnEcho "pi replaced its settings symlink with a regular file; adopting it into ${statePath}"
              run mkdir -p "$(dirname "${statePath}")"
              run mv -f "${linkPath}" "${statePath}"
            fi
          '';
        };
    })
  ]);
}
