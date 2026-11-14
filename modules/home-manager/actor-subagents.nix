# The patched pi-actor-subagents (`programs.pi.actorSubagents`): background agents spawned and
# supervised from a pi session. The upstream extension with three local patches
# (../../packages/actor-subagents/package.nix), which add the stable `globalThis.__subagentsApi_v1`
# other extensions drive. Linked through the registry; not loaded into children. Its settings file
# <agentDir>/actor-subagents/settings.json is the one place children's extensions are named
# (`childExtensions`). Nix-only: the render never maps it into the pi package.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.pi;
  a = cfg.actorSubagents;
in {
  options.programs.pi.actorSubagents = {
    enable = lib.mkEnableOption "the patched pi-actor-subagents: background agents spawned and supervised from a pi session, and the `globalThis.__subagentsApi_v1` other extensions drive";

    src = lib.mkOption {
      type = lib.types.path;
      internal = true;
      description = "The unpatched upstream source: what `package` patches and what the existence assertion probes.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../packages/actor-subagents/package.nix {inherit (a) src;};
      defaultText = lib.literalExpression "pkgs.callPackage <pi-setup>/packages/actor-subagents/package.nix { src = <input pi-actor-subagents>; }";
      description = ''
        The patched extension source (`extensions/actor-subagents`). `passthru.spawnPolicyApi` is the
        version of `globalThis.__subagentsApi_v1` it provides (1: the spawn policy; 2: also
        `spawn`/`kill`, child tools and cwd); consumers assert it.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (pkgs.formats.json {}).type;
      default = {};
      example = {
        maxAgents = 4;
        errorNoticeGraceMs = 0;
      };
      description = ''
        Merged into `<agentDir>/actor-subagents/settings.json`, which the extension reads on every
        spawn (upstream keys: `maxAgents`, `maxSpawnDepth`, `errorNoticeGraceMs`). `childExtensions`
        there comes from the registry (`extensions.<name>.forChildren`) and must not be set here:
        doing so is an assertion error.
      '';
    };

    childExtensions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      internal = true;
      default =
        map (n: "${config.home.homeDirectory}/${cfg.agentDir}/extensions/${n}")
        (lib.filter (n: cfg.extensions.${n}.forChildren) (lib.attrNames cfg.extensions));
      defaultText = lib.literalExpression ''<home>/<agentDir>/extensions/<name> of every `extensions.<name>` with `forChildren`, by name'';
      description = ''
        The settings file's `childExtensions`: the extensions every child loads, as link paths (the
        extension resolves them in a child process; a reader takes each name from the last path
        component). A layer that renders the links itself sets it.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && a.enable) {
    # The registry owns childExtensions: no silent override.
    assertions = [
      {
        assertion = !(a.settings ? childExtensions);
        message = "pi-setup: programs.pi.actorSubagents.settings.childExtensions is set; the registry owns that key (extensions.<name>.forChildren).";
      }
    ];

    # One writer; literal text, so the checks read it back with fromJSON. childExtensions on the
    # right: the registry owns that key.
    home.file."${cfg.agentDir}/actor-subagents/settings.json".text =
      builtins.toJSON (lib.recursiveUpdate a.settings {inherit (a) childExtensions;});

    # The existence assertion probes the unpatched input: probing the patched build would be
    # import-from-derivation, and a patch that no longer applies fails the package's build instead.
    programs.pi.extensions.actor-subagents = {
      path = "${a.package}/extensions/actor-subagents";
      checkPath = "${a.src}/extensions/actor-subagents/index.ts";
      input = "pi-actor-subagents";
      # Withheld from children on upstream's advice: children already receive the orchestration
      # tools through pi's customTools, and loading the extension again would put the swarm UI and
      # status panel into headless children.
      forChildren = false;
      description = "Spawns and supervises background agents from the session, with a live status panel: spawn_subagent, send_message, set_agent_model, list_agents, kill_agent, agent_history, set_status, resume_agents, plus the /agents* commands. Swarms persist beside the main session.";
    };
  };
}
