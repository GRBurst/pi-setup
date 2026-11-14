# The patched actor-subagents (`programs.pi.actorSubagents`): off by default; on, a registry entry
# linked under <agentDir>/extensions (not loaded into children) whose package is the flake's
# `packages.<system>.actor-subagents`, and whose existence assertion probes the unpatched input;
# and its settings file <agentDir>/actor-subagents/settings.json, `settings` with the children's
# extensions (`childExtensions`: the link paths of the registry's `forChildren` entries, by name),
# which `settings` must not set. The pi module alone (./lib.nix); with the economics bridge (against
# a stub of the `programs.piEconomics` options), `childExtensions` is the economics module's list,
# which renders the links then. Wired by ./default.nix as pi-setup-actor-subagents-module.
{
  lib,
  inputs,
  piLib,
  # The flake's `packages.<system>.actor-subagents`.
  actorPackage,
}: let
  inherit (piLib) mkAssertionCheck piFixtureWith piFailedWith bridge piEconomicsStub;

  on = extra:
    piFixtureWith {
      imports = [extra];
      programs.pi.actorSubagents.enable = true;
    };
  alone = piFixtureWith {};
  enabled = on {};
  custom = on {programs.pi.agentDir = "custom/agent";};
  piOff = on {programs.pi.enable = false;};

  # home.file entries by target.
  files = h: lib.mapAttrs' (_: f: lib.nameValuePair f.target f) h.home.file;
  linkOf = dir: h: let
    f = (files h)."${dir}/extensions/actor-subagents" or null;
  in
    if f == null
    then null
    else "${f.source}";
  hasFileUnder = dir: h: lib.any (lib.hasPrefix "${dir}/actor-subagents/") (lib.attrNames (files h));

  a = enabled.programs.pi.actorSubagents;
  entry = enabled.programs.pi.extensions.actor-subagents;

  # Two children out of name order and one entry withheld from them, next to the built-ins
  # (claude-auth is for children too).
  fixtureEntry = forChildren: {
    path = inputs.pi-question;
    inherit forChildren;
    description = "a fixture entry";
  };
  registry = {
    programs.pi.extensions = {
      zeta = fixtureEntry true;
      alpha = fixtureEntry true;
      mid = fixtureEntry false;
    };
  };
  textAt = target: h: ((files h).${target} or {text = null;}).text;
  settingsOf = dir: h: builtins.fromJSON (textAt "${dir}/actor-subagents/settings.json" h);
  # The children of h's registry, as link paths under dir.
  childrenAt = dir: h: names: map (n: "${h.home.homeDirectory}/${dir}/extensions/${n}") names;
  withSettings = s:
    on {
      imports = [registry];
      programs.pi.actorSubagents.settings = s;
    };
  kidsOf = h: h.programs.pi.actorSubagents.childExtensions;
in
  mkAssertionCheck "pi-setup-actor-subagents-module" [
    {
      condition =
        !alone.programs.pi.actorSubagents.enable
        && !(alone.programs.pi.extensions ? actor-subagents)
        && linkOf ".pi/agent" alone == null
        && !(hasFileUnder ".pi/agent" alone);
      message = "actor-subagents: off by default: no registry entry, no link, no settings file";
    }
    {
      condition =
        {inherit (entry) path checkPath input forChildren;}
        == {
          path = "${a.package}/extensions/actor-subagents";
          checkPath = "${a.src}/extensions/actor-subagents/index.ts";
          input = "pi-actor-subagents";
          forChildren = false;
        }
        && linkOf ".pi/agent" enabled == "${a.package}/extensions/actor-subagents"
        && piFailedWith {programs.pi.actorSubagents.enable = true;} == [];
      message = "actor-subagents: on, the registry entry (patched path, unpatched checkPath, input, not for children) is linked and no assertion fails";
    }
    {
      condition =
        "${a.src}"
        == "${inputs.pi-actor-subagents}"
        && a.package.drvPath == actorPackage.drvPath
        && a.package.name == "pi-actor-subagents-patched"
        && (a.package.passthru.spawnPolicyApi or 0) == 2;
      message = "actor-subagents: the package is the flake's actor-subagents output (pi-actor-subagents-patched, spawnPolicyApi 2), built from the input";
    }
    {
      condition =
        piFailedWith {
          programs.pi.actorSubagents = {
            enable = true;
            src = inputs.pi-question;
          };
        }
        == ["pi-setup: extension 'actor-subagents' not found at ${inputs.pi-question}/extensions/actor-subagents/index.ts; the pi-actor-subagents input may have renamed or removed it."];
      message = "actor-subagents: a source without the extension fails the existence assertion, which names the input";
    }
    {
      condition = linkOf "custom/agent" custom == "${a.package}/extensions/actor-subagents" && linkOf ".pi/agent" custom == null;
      message = "actor-subagents: the link follows agentDir";
    }
    {
      condition = lib.all (dir: let
        h = on {
          imports = [registry];
          programs.pi.agentDir = dir;
        };
        kids = kidsOf h;
      in
        kids
        == childrenAt dir h ["alpha" "claude-auth" "zeta"]
        && lib.all (p: (files h) ? ${lib.removePrefix "${h.home.homeDirectory}/" p}) kids)
      [".pi/agent" "custom/agent"];
      message = "actor-subagents: childExtensions is the link paths of the registry's forChildren entries, by name, each a rendered link (both agentDirs)";
    }
    {
      condition = let
        h = withSettings {};
      in
        textAt ".pi/agent/actor-subagents/settings.json" h
        == builtins.toJSON {childExtensions = kidsOf h;}
        && textAt "custom/agent/actor-subagents/settings.json" custom
        == builtins.toJSON {childExtensions = kidsOf custom;}
        && textAt ".pi/agent/actor-subagents/settings.json" custom == null;
      message = "actor-subagents: with settings = {} the settings file is {\"childExtensions\":[...]} under agentDir";
    }
    {
      condition = let
        s = {
          maxAgents = 4;
          errorNoticeGraceMs = 0;
        };
        h = withSettings s;
      in
        settingsOf ".pi/agent" h
        == s // {childExtensions = kidsOf h;}
        && piFailedWith {
          imports = [registry];
          programs.pi.actorSubagents = {
            enable = true;
            settings = s;
          };
        }
        == [];
      message = "actor-subagents: settings merge into the settings file next to childExtensions";
    }
    {
      condition =
        piFailedWith {
          programs.pi.actorSubagents = {
            enable = true;
            settings.childExtensions = ["/elsewhere"];
          };
        }
        == ["pi-setup: programs.pi.actorSubagents.settings.childExtensions is set; the registry owns that key (extensions.<name>.forChildren)."];
      message = "actor-subagents: setting settings.childExtensions fails the assertion";
    }
    {
      condition = let
        s = {maxAgents = 4;};
        kids = ["/x/agent/extensions/b" "/x/agent/extensions/a"];
        h = on {
          imports = [bridge piEconomicsStub registry];
          programs.pi.actorSubagents.settings = s;
          programs.piEconomics.childExtensions = kids;
        };
        forwarded = h.programs.piEconomics.extensions.actor-subagents;
      in
        kidsOf h
        == kids
        && textAt ".pi/agent/actor-subagents/settings.json" h
        == builtins.toJSON (lib.recursiveUpdate s {childExtensions = kids;})
        && {inherit (forwarded) path checkPath input forChildren;}
        == {inherit (h.programs.pi.extensions.actor-subagents) path checkPath input forChildren;}
        && linkOf ".pi/agent" h == null;
      message = "actor-subagents: with the economics bridge, childExtensions is the economics module's list and the entry is forwarded, not linked here";
    }
    {
      condition = !(piOff.programs.pi.extensions ? actor-subagents) && linkOf ".pi/agent" piOff == null && !(hasFileUnder ".pi/agent" piOff);
      message = "actor-subagents: with programs.pi.enable = false nothing is registered, linked or written";
    }
  ]
