# The extension registry `programs.pi.extensions`, the built-ins and the economics bridge:
# the pi module alone links its registry under <agentDir>/extensions and asserts every entry exists; the bridge hands the registry to the economics module's (`programs.piEconomics`) instead,
# here against a stub of the `programs.piEconomics` options it sets and reads. Wired by ./default.nix as
# pi-setup-extensions.
{
  lib,
  pkgs,
  inputs,
  piLib,
}: let
  inherit (piLib) mkAssertionCheck piFixtureWith piFailedWith piFailsWith bridge;
  stub = piLib.piEconomicsStub;

  prefix = ".pi/agent/extensions/";
  links = h:
    lib.mapAttrs' (n: f: lib.nameValuePair (lib.removePrefix prefix n) "${f.source}")
    (lib.filterAttrs (n: _: lib.hasPrefix prefix n) h.home.file);

  builtins3 = {
    question = "${inputs.pi-question}/extensions/question";
    session-name = "${inputs.pi-session-name}/extensions/session-name";
    claude-auth = "${inputs.pi-claude-auth}/src";
  };

  alone = piFixtureWith {};
  indicator = piFixtureWith {programs.pi.builtinExtensions.staticWorkingIndicator.enable = true;};
  search = {programs.pi.builtinExtensions.webSearch.enable = true;};
  webSearch = piFixtureWith search;

  # A consumer's own entry: the registry is generic.
  ownDir = pkgs.writeTextDir "index.ts" "export default function () {}\n";
  own = {
    programs.pi.extensions.own = {
      path = "${ownDir}";
      input = "a test";
      forChildren = true;
      description = "a consumer's extension";
    };
  };

  bridged = piFixtureWith {imports = [bridge stub own];};
  bridgedOff = piFixtureWith {
    imports = [bridge stub];
    programs.pi.enable = false;
  };
  fields = ["path" "checkPath" "input" "forChildren" "description"];
in
  mkAssertionCheck "pi-setup-extensions" [
    {
      # P alone (linkExtensions = true): the built-ins question, session-name and claude-auth
      # (upstream source) linked under <agentDir>/extensions, nothing else.
      condition = links alone == builtins3 && alone.programs.pi.linkExtensions;
      message = "extensions: alone, pi links question, session-name and the upstream claude-auth under .pi/agent/extensions";
    }
    {
      # `claudeAuth.package` is the tree whose src/ pi loads: the upstream source (`claudeAuth.src`) by default,
      # whatever a consumer sets otherwise; only the link moves (the existence probe, key, input and children stay).
      condition = let
        e = (piFixtureWith {programs.pi.claudeAuth.package = "/nonexistent/patched";}).programs.pi.extensions.claude-auth;
      in
        "${alone.programs.pi.claudeAuth.package}"
        == "${inputs.pi-claude-auth}"
        && (links (piFixtureWith {programs.pi.claudeAuth.package = "/nonexistent/patched";})).claude-auth == "/nonexistent/patched/src"
        && e.checkPath == "${inputs.pi-claude-auth}/src/index.ts"
        && e.input == "pi-claude-auth"
        && e.forChildren;
      message = "extensions: claudeAuth.package defaults to the upstream source and redirects only the claude-auth link";
    }
    {
      condition = let
        e = alone.programs.pi.extensions;
      in
        !e.question.forChildren
        && !e.session-name.forChildren
        && e.claude-auth.forChildren
        && e.claude-auth.checkPath == "${inputs.pi-claude-auth}/src/index.ts"
        && e.question.checkPath == e.question.path
        && e.question.input == "pi-question"
        && e.session-name.input == "pi-session-name"
        && e.claude-auth.input == "pi-claude-auth";
      message = "extensions: the built-ins' registry entries (children: claude-auth only; claude-auth probes the upstream input)";
    }
    {
      condition = let
        l = links indicator;
      in
        !(links alone ? static-working-indicator)
        && lib.hasSuffix "-static-working-indicator" l.static-working-indicator
        && !indicator.programs.pi.extensions.static-working-indicator.forChildren;
      message = "extensions: static-working-indicator is off by default and linked (not for children) when enabled";
    }
    {
      # The web tools: off by default; enabled, the repository's own directory (its
      # index.ts is what pi discovers), and children get them too.
      condition = let
        l = links webSearch;
        e = webSearch.programs.pi.extensions.web-search;
      in
        !(alone.programs.pi.extensions ? web-search)
        && !(links alone ? web-search)
        && !alone.programs.pi.builtinExtensions.webSearch.enable
        && lib.hasSuffix "-web-search" l.web-search
        && builtins.pathExists "${l.web-search}/index.ts"
        && e.forChildren
        && e.input == "the pi module's own extensions directory"
        && piFailedWith search == [];
      message = "extensions: web-search is off by default and linked as .pi/agent/extensions/web-search (for children) when enabled";
    }
    {
      # Through the bridge the children's list gets the web tools.
      condition = let
        h = piFixtureWith {
          imports = [bridge stub search];
        };
        pe = h.programs.piEconomics.extensions;
      in
        links h
        == {}
        && pe ? web-search
        && pe.web-search.forChildren
        && lib.all (f: pe.web-search.${f} == h.programs.pi.extensions.web-search.${f}) fields;
      message = "extensions: the bridge forwards web-search to the economics registry, for children";
    }
    {
      condition =
        links (piFixtureWith {
          programs.pi.builtinExtensions.question.enable = false;
          programs.pi.builtinExtensions.sessionName.enable = false;
          programs.pi.claudeAuth.enable = false;
        })
        == {};
      message = "extensions: question and session-name follow their enable, claude-auth follows claudeAuth.enable";
    }
    {
      condition = let
        h = piFixtureWith {
          imports = [own];
          programs.pi.agentDir = ".pi/elsewhere";
        };
      in
        lib.attrNames (lib.filterAttrs (n: _: lib.hasPrefix ".pi/elsewhere/extensions/" n) h.home.file)
        == map (n: ".pi/elsewhere/extensions/${n}") ["claude-auth" "own" "question" "session-name"]
        && "${h.home.file.".pi/elsewhere/extensions/own".source}" == "${ownDir}"
        && links h == {};
      message = "extensions: a consumer's entry is linked like the built-ins, under a moved agentDir";
    }
    {
      condition = piFailedWith {imports = [own];} == [];
      message = "extensions: existing entries pass the existence assertions";
    }
    {
      condition = piFailsWith "pi-setup: extension 'gone' not found at /nonexistent/gone; the a test input may have renamed or removed it." {
        programs.pi.extensions.gone = {
          path = "/nonexistent/gone";
          input = "a test";
          forChildren = false;
          description = "missing";
        };
      };
      message = "extensions: an entry whose checkPath does not exist must fail the module assertion";
    }
    {
      condition = let
        h = piFixtureWith {programs.pi.linkExtensions = false;};
      in
        links h
        == {}
        && h.programs.pi.extensions ? question
        && piFailedWith {
          programs.pi.linkExtensions = false;
          programs.pi.extensions.gone = {
            path = "/nonexistent/gone";
            forChildren = false;
            description = "missing";
          };
        }
        == [];
      message = "extensions: linkExtensions = false renders neither links nor existence assertions (the registry stays)";
    }
    {
      # The bridge: linkExtensions off, the registry forwarded field by field (forChildren
      # included), the settings file and the DAG after the seed and the reclaim.
      condition = let
        pe = bridged.programs.piEconomics;
        reg = bridged.programs.pi.extensions;
      in
        !bridged.programs.pi.linkExtensions
        && links bridged == {}
        && lib.attrNames pe.extensions == ["claude-auth" "own" "question" "session-name"]
        && lib.all (n: lib.all (f: (pe.extensions.${n}.${f} or null) == reg.${n}.${f}) fields) (lib.attrNames reg)
        && lib.mapAttrs (_: e: e.forChildren or null) pe.extensions
        == {
          claude-auth = true;
          own = true;
          question = false;
          session-name = false;
        }
        && pe.piSettings.file == bridged.programs.pi.settings.stateFile
        && pe.piSettings.after == ["piSettingsSeed" "piSettingsReclaim"]
        && pe.taskRouter.settings == {};
      message = "extensions: the bridge turns linking off and forwards the registry field by field, the state file and piSettings.after";
    }
    {
      condition = let
        pe = bridgedOff.programs.piEconomics;
      in
        pe.extensions == {} && pe.piSettings.file == "unset" && pe.piSettings.after == [];
      message = "extensions: the bridge sets nothing while programs.pi is off";
    }
    {
      # Declares nothing, imports nothing: valid only next to the economics module (`programs.piEconomics`).
      condition =
        lib.attrNames (import bridge {
          inherit lib;
          config = bridged;
        })
        == ["config"];
      message = "extensions: the bridge module declares no options and imports nothing";
    }
  ]
