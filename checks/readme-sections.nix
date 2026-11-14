# The README as a user's first page (the sandbox repository's form): the sections exist, the words a user needs
# are in them, and the commands the README tells a user to run do what it says.
#
# - headings: `## Install with Nix`, `## Without Nix`, `## Options`, `## Ports`,
#   `## Web search`, `## Local search without NixOS`, `## Checks`, `## Licence`;
# - the intro says "works without Nix through pi's package system" and "first-class Nix support";
# - per section, the words in `mentions` occur in it;
# - Ports: the pi-web row names both ports as whole numbers and the listen address default of
#   the evaluated module (`programs.aiSandbox.services.pi-web.proxy.listenAddress`); the
#   SearXNG row names the default `search.local.port` and its bind address, `127.0.0.1`;
# - the caveat pin: the sentence that forbids a write grant to `~/.claude` is in "Without Nix";
# - the seed merge: the README's merge line, run on two fixtures, keeps the existing keys
#   and adds the seed's; a `settings.json` that does not exist is covered by copying the seed.
{
  pkgs,
  lib,
  self,
  home-manager,
}: let
  fixture = (import ./module/lib.nix {
    inherit pkgs lib home-manager;
    inputs = self.inputs;
    piWeb = ../packages/pi-web;
  }).piFixtureWith {programs.pi.web.enable = true;};
  web = fixture.programs.pi.web;
  listenAddress = fixture.programs.aiSandbox.services.pi-web.proxy.listenAddress;
  searxPort = fixture.programs.pi.search.local.port;

  phrase = "first-class Nix support";
  intro = "works without Nix through pi's package system";
  headings = ["Install with Nix" "Without Nix" "Options" "Ports" "Web search" "Local search without NixOS" "Checks" "Licence"];
  caveat = "Do not grant the sandbox write access to `~/.claude`";
  seedMerge = "jq -s '.[1] + .[0]' settings.json <checkout>/settings/seed.json";
  # the README's line run from the fixture, where the seed sits at ./settings/seed.json
  seedRun = builtins.replaceStrings ["<checkout>"] ["."] seedMerge;
  pkgName = (builtins.fromJSON (builtins.readFile "${self}/package.json")).name;

  lines = lib.splitString "\n" (builtins.readFile "${self}/README.md");
  # the lines from `## <name>` up to the next level-2 heading; [] when there is no such heading
  sectionOf = name: let
    at = lib.lists.findFirstIndex (l: l == "## ${name}") null lines;
    from = lib.drop (at + 1) lines;
  in
    if at == null
    then []
    else lib.take (lib.lists.findFirstIndex (lib.hasPrefix "## ") (lib.length from) from) from;
  textOf = name: lib.concatStringsSep "\n" (sectionOf name);

  mentions = {
    "Install with Nix" = [
      "homeModules.default"
      "homeModules.piEconomics"
      "follows"
      "programs.aiSandbox.enable"
      "programs.pi.enable"
      "programs.pi.package"
      "settings.manage"
      "claudeAuth.package"
      "claudeAuth.setConfigDir"
      "inputs.home-manager.follows = \"home-manager\""
      "claudeAuth.enable = false"
      "examples/existing-flake"
    ];
    "Without Nix" = [
      "pi install git:github.com/GRBurst/${pkgName}@"
      "pi install ."
      "git:git@github.com:GRBurst/pi-setup@"
      "!extensions/static-working-indicator/**"
      "npm install --omit=dev --legacy-peer-deps"
      "!node_modules/@fdietze/pi-claude-auth/**"
      "settings/seed.json"
      seedMerge
      "claude-auth"
      "~/.claude"
      caveat
      "Nix-only"
      "programs.pi.actorSubagents"
    ];
    "Options" = ["no default" "programs.pi"];
    "Ports" = [(toString web.listenPort) (toString web.backendPort) listenAddress];
    "Web search" = [
      "programs.pi.builtinExtensions.webSearch.enable = true"
      "`web_search`"
      "`web_fetch`"
      "PI_SEARX_URL"
      "TAVILY_API_KEY"
      "BRAVE_API_KEY"
      "not Nix options"
      "third part"
      "directly"
      "private"
      "child"
      "\"!extensions/web-search/**\""
    ];
    "Local search without NixOS" = [
      "programs.pi.search.local.enable = true"
      "PI_SEARX_URL"
      "pi-searx-up"
      "pi-searx-down"
      "/healthz"
      "reused"
      "preStart"
      "TMPDIR"
      "$XDG_STATE_HOME/pi-searx"
      "0600"
      "keep_only"
      "reuseExisting"
      "trust decision"
      "PI_SEARX_WAIT"
      "`foreign`"
      "`lock`"
      "loopback"
    ];
    "Checks" = ["nix build .#checks.x86_64-linux."];
  };

  missingWords = lib.concatLists (lib.mapAttrsToList (
      s: words: let
        t = textOf s;
      in
        map (w: "## ${s} does not mention `${w}`") (lib.filter (w: !(lib.hasInfix w t)) words)
    )
    mentions);

  missingHeadings = map (h: "no `## ${h}` heading") (lib.filter (h: sectionOf h == []) headings);

  introProblems =
    lib.optional (!(lib.hasInfix intro (lib.concatStringsSep "\n" lines))) "README.md does not say \"${intro}\""
    ++ lib.optional (!(lib.hasInfix phrase (lib.concatStringsSep "\n" lines))) "README.md does not say \"${phrase}\"";

  # Ports: the pi-web row names both ports and the listen address
  portRows = lib.filter (lib.hasPrefix "| ") (sectionOf "Ports");
  hasNumber = row: n: builtins.match "(.*[^0-9])?${toString n}([^0-9].*)?" row != null;
  portProblems =
    lib.optional (!(lib.any (row: lib.hasInfix "pi-web" row && hasNumber row web.listenPort && lib.hasInfix listenAddress row) portRows))
    "## Ports has no pi-web row naming ${toString web.listenPort} and ${listenAddress}"
    ++ lib.optional (!(lib.any (row: lib.hasInfix "pi-web" row && hasNumber row web.backendPort) portRows))
    "## Ports has no pi-web row naming ${toString web.backendPort}"
    ++ lib.optional (!(lib.any (row: lib.hasInfix "SearXNG" row && hasNumber row searxPort && lib.hasInfix "127.0.0.1" row) portRows))
    "## Ports has no SearXNG row naming ${toString searxPort} and 127.0.0.1";

  # The seed merge: the README's merge line, run on fixtures in the shape it expects.
  seedProblems = lib.optional (!(lib.hasInfix seedMerge (textOf "Without Nix"))) "## Without Nix does not give the seed merge line";
  seedCheck = pkgs.runCommand "readme-sections-seed" {nativeBuildInputs = [pkgs.jq pkgs.coreutils];} ''
    mkdir fixture && cd fixture
    mkdir settings && cp ${self}/settings/seed.json settings/seed.json
    # existing keys win; the seed's keys fill the rest
    printf '%s\n' '{"packages": ["x"], "defaultThinkingLevel": "high"}' >settings.json
    ${seedRun} >merged.json
    jq -e '.packages == ["x"] and .defaultThinkingLevel == "high"' merged.json >/dev/null \
      || { echo "readme-sections: the seed merge lost an existing key" >&2; cat merged.json >&2; exit 1; }
    # an empty settings file takes the seed's keys
    printf '%s\n' '{}' >settings.json
    ${seedRun} >merged.json
    diff <(jq -S . merged.json) <(jq -S . settings/seed.json) \
      || { echo "readme-sections: the seed merge does not add the seed's keys" >&2; exit 1; }
    touch $out
  '';

  problems = missingHeadings ++ introProblems ++ missingWords ++ portProblems ++ seedProblems;
in
  pkgs.runCommand "readme-sections" {} (
    if problems == []
    then "cp ${seedCheck} $out"
    else "printf '%s\\n' ${lib.escapeShellArg "readme-sections:\n  ${lib.concatStringsSep "\n  " problems}"} >&2; exit 1"
  )
