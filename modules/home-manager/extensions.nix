# pi's extension registry `programs.pi.extensions` and the built-in extensions.
#
# pi auto-discovers global extensions ONLY under <agentDir>/extensions/*.ts and
# <agentDir>/extensions/*/index.ts (pi's extensions documentation); anywhere else
# evaluates fine, links fine and yields zero tools. They are loaded uncompiled through jiti
# and import nothing beyond what pi itself ships, so there is no build step and no
# node_modules.
#
# The registry is keyed by INSTALL name, which is also the directory pi discovers. It has the
# shape of the economics module's registry (`programs.piEconomics.extensions`): with `linkExtensions`
# (the default) this module renders the links and the existence assertions itself; the
# economics bridge (./economics-bridge.nix) turns that off and forwards the registry,
# which the economics module then renders as links, assertions and the children's list.
#
# Built-ins: question, session-name (on), static-working-indicator, web-search (off); claude-auth follows
# `claudeAuth.enable` (./claude-auth.nix). Their sources are internal `src` options, set by
# ./flake-module.nix from the flake's inputs.
{
  config,
  lib,
  ...
}: let
  cfg = config.programs.pi;
  b = cfg.builtinExtensions;

  # One registry entry, the same fields as the economics module's registry entries.
  extensionModule = {config, ...}: {
    options = {
      path = lib.mkOption {
        type = lib.types.path;
        description = "What `<agentDir>/extensions/<name>` links to: the extension's directory.";
      };
      checkPath = lib.mkOption {
        type = lib.types.path;
        default = config.path;
        defaultText = lib.literalExpression "path";
        description = ''
          What the existence assertion probes. For a patched source, the unpatched input's
          entry file: probing a derivation's output would be import-from-derivation, and a
          patch that no longer applies fails the package's build instead.
        '';
      };
      input = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Where the extension comes from; the existence assertion names it.";
      };
      forChildren = lib.mkOption {
        type = lib.types.bool;
        description = "Whether background child agents load the extension (read by the economics module).";
      };
      description = lib.mkOption {
        type = lib.types.str;
        description = "What the extension does.";
      };
    };
  };

  builtinOption = name: default: {
    enable = lib.mkEnableOption "the built-in extension ${name}" // {inherit default;};
    src = lib.mkOption {
      type = lib.types.path;
      internal = true;
      description = "The source the built-in extension ${name} is taken from.";
    };
  };
in {
  options.programs.pi = {
    extensions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule extensionModule);
      default = {};
      description = ''
        The extension registry, keyed by install name: each entry is linked as
        `<agentDir>/extensions/<name>` and its `checkPath` must exist. The built-ins add
        themselves; a consumer adds its own extensions.
      '';
    };

    builtinExtensions = {
      question = builtinOption "question" true;
      sessionName = builtinOption "session-name" true;
      staticWorkingIndicator =
        builtinOption "static-working-indicator" false
        // {
          src = lib.mkOption {
            type = lib.types.path;
            internal = true;
            default = ../../extensions/static-working-indicator;
            description = "The source the built-in extension static-working-indicator is taken from.";
          };
        };
      webSearch =
        builtinOption "web-search" false
        // {
          src = lib.mkOption {
            type = lib.types.path;
            internal = true;
            default = ../../extensions/web-search;
            description = "The source the built-in extension web-search is taken from.";
          };
        };
    };

    linkExtensions = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this module links the registry and asserts its entries exist. The economics
        bridge sets it to false and forwards the registry to the economics module's own.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      programs.pi.extensions =
        lib.optionalAttrs b.question.enable {
          # Withheld from children: a background agent has no TUI to render the question in.
          question = {
            path = "${b.question.src}/extensions/question";
            input = "pi-question";
            forChildren = false;
            description = "A question tool rendered in a bottom dock, with multi-select checkboxes and a shared free-form note; interrupted calls are recovered on the next start.";
          };
        }
        // lib.optionalAttrs b.sessionName.enable {
          session-name = {
            path = "${b.sessionName.src}/extensions/session-name";
            input = "pi-session-name";
            forChildren = false;
            description = "setSessionName: names the current session so the terminal tab title, session selector and footer show what is being worked on.";
          };
        }
        // lib.optionalAttrs b.staticWorkingIndicator.enable {
          # Local to this module; withheld from children: a headless child has no TUI and no
          # working indicator to make static. The whole directory is copied into the store
          # under its own basename.
          static-working-indicator = {
            path = "${b.staticWorkingIndicator.src}";
            input = "the pi module's own extensions directory";
            forChildren = false;
            description = "Replaces pi's animated working spinner with a static glyph, which removes the loader's timer and with it the fullscreen repaint of the whole transcript ~12 times a second (upstream issue 3881).";
          };
        }
        // lib.optionalAttrs b.webSearch.enable {
          # Local to this module, like the indicator; for children too: no UI, and all network
          # I/O happens inside the tool calls. The backend comes from the environment
          # (PI_SEARX_URL, TAVILY_API_KEY, BRAVE_API_KEY), which children inherit.
          web-search = {
            path = "${b.webSearch.src}";
            input = "the pi module's own extensions directory";
            forChildren = true;
            description = "The tools web_search (SearXNG, Tavily or Brave, chosen by environment variables) and web_fetch (a public http(s) page as markdown, converted locally, with private and internal addresses refused).";
          };
        };
    }

    (lib.mkIf cfg.linkExtensions {
      # Plain store sources, not out-of-store links.
      home.file = lib.mapAttrs' (name: e:
        lib.nameValuePair "${cfg.agentDir}/extensions/${name}" {source = e.path;})
      cfg.extensions;

      # An upstream rename breaks evaluation instead of leaving a link that pi silently skips.
      assertions =
        lib.mapAttrsToList (name: e: {
          assertion = builtins.pathExists e.checkPath;
          message =
            "pi-setup: extension '${name}' not found at ${toString e.checkPath}"
            + (
              if e.input == null
              then "."
              else "; the ${e.input} input may have renamed or removed it."
            );
        })
        cfg.extensions;
    })
  ]);
}
