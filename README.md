# pi-setup

The pi coding agent running inside `ai-sandbox`, as a pi package and as Home Manager
modules. Public, MIT licensed (see `LICENSE`).

This repository works without Nix through pi's package system. The Nix modules and
flake outputs give first-class Nix support for frictionless use with Nix.

## Install with Nix

Use the flake's inputs and follow your own `nixpkgs`, `home-manager` and
`ai-sandbox`; `examples/existing-flake/flake.nix` is a complete example:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  home-manager = {
    url = "github:nix-community/home-manager";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  ai-sandbox = {
    url = "github:GRBurst/ai-sandbox";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.home-manager.follows = "home-manager";
  };
  pi-setup = {
    url = "github:GRBurst/pi-setup";
    inputs = {
      nixpkgs.follows = "nixpkgs";
      home-manager.follows = "home-manager";
      ai-sandbox.follows = "ai-sandbox";
    };
  };
};
```

Import `homeModules.default` and enable the sandbox and pi:

```nix
home-manager.users.me = {
  imports = [inputs.pi-setup.homeModules.default];
  programs.aiSandbox.enable = true;
  programs.pi.enable = true;
  programs.pi.package = pkgs.pi-coding-agent; # or null if pi comes from elsewhere
};
```

Without `programs.pi.package` (default `null`) no `pi` binary is installed, and the
`pi` and `pi_nono` aliases find none on `PATH`.

The options below are under `programs.pi`. Three of them matter first:
`settings.manage` (default `true`) links `<agentDir>/settings.json` to a state file
and seeds it once; `claudeAuth.package` is the `claude-auth` source (default: the
upstream); `claudeAuth.setConfigDir` (default `false`) moves pi's Claude
config dir (upstream honours `CLAUDE_CONFIG_DIR`; turning it on needs
`pi-claude-login` once). The economics
bridge `homeModules.piEconomics` is a module path: a layer that declares
`programs.piEconomics` imports it, and it forwards `programs.pi`'s extension
registry, agent dir and settings file to `programs.piEconomics`, and takes
that module's children list back for the actor-subagents settings file.

The Nix side has the same `claude-auth` caveat as the package: unless
`claudeAuth.setConfigDir` is on, token refresh inside the sandbox needs write access to
`~/.claude`, which you should never grant (see the caveat under Without Nix). With
`setConfigDir`, pi uses its own Claude dir instead; without it, you can turn the
extension off with `programs.pi.claudeAuth.enable = false`.

## Without Nix

Install the package from git with pi:

    pi install git:github.com/GRBurst/pi-setup@<ref>

`<ref>` is a tag or a commit; pi pins both. Over SSH: `pi install git:git@github.com:GRBurst/pi-setup@<ref>`.

From a local checkout, install the npm dependencies first; pi does not install the
dependencies of a local package:

    cd <checkout>
    npm install --omit=dev --legacy-peer-deps
    pi install .

To leave a resource out, use the settings object form of the package in
`settings.json`. For example, leave out `claude-auth` and the static working
indicator (the indicator is off by default in the Nix modules; `claude-auth` is on):

    "packages": [
      {
        "source": "git:github.com/GRBurst/pi-setup@<tag>",
        "extensions": [
          "!node_modules/@fdietze/pi-claude-auth/**",
          "!extensions/static-working-indicator/**"
        ]
      }
    ]

The package ships `settings/seed.json`. Without Nix pi owns `settings.json`, so merge
the seed in once; existing keys win. `<checkout>` is the local checkout (after
`pi install git:…`, pi's clone is `~/.pi/agent/git/github.com/GRBurst/pi-setup`).
If there is no `settings.json` yet, start from `{}`:

    cd ~/.pi/agent
    [ -f settings.json ] || echo '{}' > settings.json
    jq -s '.[1] + .[0]' settings.json <checkout>/settings/seed.json > settings.merged.json && mv settings.merged.json settings.json

Do not also link the extensions by hand or through Nix: they would conflict (pi refuses
the second copy of a tool) or load twice.

**claude-auth caveat.** The package's `claude-auth` is the upstream extension.
It reads Claude Code's credentials from `CLAUDE_CONFIG_DIR`, else `~/.claude`, and
refreshes them by running `claude -p`, which writes there. Under nono the pi profile
does not make `~/.claude` writable, so token refresh fails in the sandbox. Point
`CLAUDE_CONFIG_DIR` at a directory the profile can write (and log in there once), or
turn the extension off with the object form above.
Do not grant the sandbox write access to `~/.claude`: an agent could then write Claude
Code settings or hooks that an unsandboxed `claude` runs.

Nix-only (no `pi install` equivalent): the sandbox (`programs.aiSandbox`), the pi-web
service (`programs.pi.web`), the local SearXNG (`programs.pi.search.local`), the
economics bridge (`homeModules.piEconomics`), the
`claude-auth` config dir (`claudeAuth.setConfigDir`) and the `pi-claude-login` helper,
the patched actor-subagents (`programs.pi.actorSubagents`: a build of the upstream extension
with the patches under `patches/pi-actor-subagents`; without it, an extension that needs its
`globalThis.__subagentsApi_v1` finds none and says so),
and the settings link, seed and reclaim that `settings.manage` controls. The sandbox
itself does not need Nix: without Nix, install ai-sandbox with its own installer
(`scripts/install.sh install`); its `pi` profile runs this package.

## Outputs

- `homeModules.default`: imports `ai-sandbox`'s module and `programs.pi`
  (key `pi-setup#homeModules.default`). Importing it alone is enough.
- `homeModules.piEconomics`: the economics bridge, a module path. A module that
  declares `programs.piEconomics` imports it; it forwards the extension registry,
  the agent dir and the settings file to that module, and sets
  `programs.pi.actorSubagents`' children list from that module's.
- `packages.<system>.pi-web`: the pi-web web UI package; the service is
  `programs.pi.web` (Nix-only).
- `packages.<system>.actor-subagents`: the patched pi-actor-subagents
  (`pi-actor-subagents-patched`, `passthru.spawnPolicyApi = 2`), the default of
  `programs.pi.actorSubagents.package` (Nix-only).
- `apps.<system>.render`: `nix run .#render` writes `package.json` and
  `settings/seed.json` into the checkout.
- `legacyPackages.<system>.render-tree`: the rendered tree, built on its own.
- `checks.<system>`: `formatting`, `leaks`, `readme-options`, the module checks
  `settings`, `claude-auth`, `extensions`, `search`, `search-local`,
  `search-local-run`, `web`, `fixtures`,
  `shellcheck`, `actionlint`, `doc-refs`, `boundary`, `agent-web-prune`,
  `render-seed`, `render-package`, `render-nix-only`, `pi-package-manifest`, `pi-install-smoke`,
  `readme-sections`, `existing-flake-example`, `web-search`, `actor-subagents`
  (the upstream suite of the patched build), `typecheck-actor-subagents`,
  `actor-subagents-module`, `npm-deps`, `typecheck-harness`.
- `formatter.<system>`: Alejandra.

Inputs: `nixpkgs`, `home-manager` (both followed by consumers),
`ai-sandbox`, and the extension sources `pi-question`, `pi-session-name`,
`pi-claude-auth` and `pi-actor-subagents` (pinned by revision in the URL, `flake = false`).
The `ai-sandbox` input is `github:GRBurst/ai-sandbox`.

## Options

All under `programs.pi`. The check `readme-options` keeps the option names in this
table and the option tree in step; it does not check the defaults. A `—` in the Default column means the option is required,
no default. `extensions.<name>.*` describes one registry entry.

| Option | Default | Meaning |
| --- | --- | --- |
| `actorSubagents.enable` | `false` | The patched pi-actor-subagents (Nix-only): background agents spawned and supervised from a pi session, and the `globalThis.__subagentsApi_v1` other extensions drive. Registry entry `actor-subagents`, withheld from children. |
| `actorSubagents.package` | this repository's `actor-subagents` | The patched source (`packages.<system>.actor-subagents`: the upstream input with the patches under `patches/pi-actor-subagents`). `passthru.spawnPolicyApi` is the API version it provides (1: the spawn policy; 2: also `spawn`/`kill`, child tools and cwd). |
| `actorSubagents.settings` | `{ }` | Merged into `<agentDir>/actor-subagents/settings.json` (`maxAgents`, `maxSpawnDepth`, `errorNoticeGraceMs`). `childExtensions` there is always the registry's (the link paths of the `forChildren` entries; with the economics bridge, the economics module's list); setting it here is an assertion error. |
| `agentDir` | `".pi/agent"` | pi's agent dir, relative to the home directory (`PI_CODING_AGENT_DIR`). The economics bridge forwards it. |
| `builtinExtensions.question.enable` | `true` | Link the `question` extension: a question tool in a bottom dock, withheld from children. |
| `builtinExtensions.sessionName.enable` | `true` | Link the `session-name` extension: names the session so the tab title, selector and footer show what is worked on. |
| `builtinExtensions.staticWorkingIndicator.enable` | `false` | Link `static-working-indicator`, which replaces pi's animated working spinner with a static glyph (no timer, no repaint of the transcript). |
| `builtinExtensions.webSearch.enable` | `false` | Link `web-search`: the tools `web_search` (SearXNG, Tavily or Brave, chosen by environment variables) and `web_fetch` (a public page as markdown), for children too (see Web search). |
| `claudeAuth.credentialsFile` | read-only | Absolute path of the Claude credentials file the extension reads, for consumers outside the sandbox: `<dir>/.credentials.json` with `setConfigDir`, else `~/.claude/.credentials.json`. |
| `claudeAuth.dir` | `"$HOME/.pi/claude"` | The Claude config dir inside every pi sandbox (`CLAUDE_CONFIG_DIR`), used only with `setConfigDir`: absolute or starting with `$HOME/`. Under `$HOME/.pi` the pi pack's grant covers it; elsewhere it is granted read+write to every profile that extends the pack. |
| `claudeAuth.enable` | `true` | The `claude-auth` extension (Claude subscription auth for pi) and, with `setConfigDir`, pi's own Claude dir. |
| `claudeAuth.login.enable` | `true` | `pi-claude-login`, the one-time `claude auth login` into `dir`, run inside the pi sandbox; needs `setConfigDir`, the sandbox and its pi harness. |
| `claudeAuth.package` | the upstream source | The tree whose `src/` pi loads as `claude-auth`. The default is the extension's own upstream source; a layer may set another build. Only the link moves: the key, the children policy and the existence check stay. |
| `claudeAuth.setConfigDir` | `false` | Wire pi's Claude dir: `CLAUDE_CONFIG_DIR = dir` on every profile that extends the pi pack, the grant for a dir outside `$HOME/.pi`, its creation at activation and `pi-claude-login`. Upstream honours `CLAUDE_CONFIG_DIR`. Off by default so that existing setups see no change: turning it on moves pi's Claude login to `dir`, so `pi-claude-login` must run once. |
| `enable` | `false` | The pi coding agent: its settings file, extensions and services, inside the sandbox. |
| `extensions.<name>.checkPath` | the entry's `path` | What the existence assertion probes; set it when `path` is a derivation, so the check needs no build. |
| `extensions.<name>.description` | — | What the extension does. |
| `extensions.<name>.forChildren` | — | Whether background child agents load the extension: the actor-subagents settings file's `childExtensions` (with the economics bridge, the economics module's list). |
| `extensions.<name>.input` | `null` | Where the extension comes from; the existence assertion names it. |
| `extensions.<name>.path` | — | The extension's directory, which `<agentDir>/extensions/<name>` links to. |
| `linkExtensions` | `true` | Link the registry and assert its entries exist. The economics bridge sets it to `false` and forwards the registry. |
| `package` | `null` | The pi package, installed when non-null (a consumer may install pi itself). |
| `router.localHealthUrl` | `null` | Health URL of the local model's server, for a task router module that reads it (its local model's health); nothing in this repository reads it, the economics bridge does not forward it. `null`: unset. |
| `search.local.enable` | `false` | An on-demand SearXNG on `127.0.0.1` without NixOS or systemd: `pi-searx-up`, `pi-searx-down`, and the `pi` aliases (`pi`, `pi_nono`, variants) starting it first through ai-sandbox's `preStart` hook (see Local search without NixOS). Sets `search.searxUrl` (mkDefault) to `http://127.0.0.1:<port>`. |
| `search.local.package` | `pkgs.searxng` | The SearXNG package; its main program serves the rendered settings. |
| `search.local.port` | `8888` | Loopback port. Whatever already answers `/healthz` there is reused instead of started (logged as such) and left alone by `pi-searx-down`; see `reuseExisting`. |
| `search.local.reuseExisting` | `true` | Reuse a server on the port that `pi-searx-up` did not start. A trust decision, see Local search without NixOS. `false`: `pi-searx-up` fails when it finds one, and the `pi` aliases start pi without `PI_SEARX_URL`, so without search. |
| `search.local.settings` | `{ }` | SearXNG settings merged key by key over the base: upstream defaults with their engines (`use_default_settings = true`), limiter off, `search.formats = [ "html" "json" ]`. `search.formats` must keep `json`; `server.bind_address` (`127.0.0.1`), `server.port` and `server.secret_key` (per user, at the first start) are the module's. |
| `search.searxUrl` | `null`; `http://127.0.0.1:<port>` with `search.local.enable` | The SearXNG instance for the built-in `web_search` (`builtinExtensions.webSearch.enable`) or any extension that reads `PI_SEARX_URL`, exported as that variable; `null` sets no variable. Derive it from the instance that actually runs, never from a literal. |
| `settings.manage` | `true` | Manage `<agentDir>/settings.json`: the out-of-store link to `settings.stateFile`, the one-time seed, the reclaim of a file pi overwrote and the state-file grant. `false` leaves the file to pi alone and the economics bridge refuses it. |
| `settings.reclaim.enable` | `programs.aiSandbox.enable` | Adopt a regular file pi wrote over the settings link into the state file, before Home Manager's clobber check. |
| `settings.seed` | `{ packages = [ ]; }` | Initial content of `settings.json`, merged key by key; written once, only if the state file does not exist. Delete the state file and switch again to apply a changed seed. |
| `settings.stateFile` | `".local/state/pi/settings.json"` | The mutable file `<agentDir>/settings.json` links to, relative to the home directory. |
| `settings.stateGrant` | read-only | The state file as granted on the pi pack (nono expands it): the sandbox resolves the settings link to its target. |
| `web.backendPort` | `15433` | Loopback port the pi-web server binds. |
| `web.dataDir` | `"$HOME/.pi-web"` | pi-web's data dir (`PI_WEB_DATA_DIR`): uploads, the session daemon's owner file and socket, plugin state. Absolute or starting with `$HOME`. |
| `web.enable` | `false` | pi-web (`@jmfederico/pi-web`) as a sandboxed user service behind a compressing proxy; needs `programs.aiSandbox.enable` and `enable`, and refuses a port used twice. |
| `web.listenPort` | `15432` | Port the proxy listens on, which a browser connects to. Never opened in a firewall by this module: pi-web has no authentication and exposes an agent with full tool access. |
| `web.package` | this repository's `pi-web` | The pi-web package: its own build with a committed lockfile. `pi install` cannot provision it (the peers are skipped). |

## Ports

The pi-web service (`programs.pi.web`) and the local SearXNG (`programs.pi.search.local`),
both off by default. The module opens nothing in the firewall: pi-web has no
authentication and exposes an agent with full tool access, and SearXNG serves this
machine only.

| Port | Bound to | Service | Notes |
| --- | --- | --- | --- |
| 15432 | the proxy's listen address (`programs.aiSandbox.services.pi-web.proxy.listenAddress`, default `127.0.0.1`) | pi-web proxy | `web.listenPort`; the compressing proxy a browser connects to |
| 15433 | `127.0.0.1` | pi-web server | `web.backendPort`; the backend behind the proxy |
| 8888 | `127.0.0.1` | SearXNG | `search.local.port`; started by `pi-searx-up`, no bind option |

## Web search

`programs.pi.builtinExtensions.webSearch.enable = true` links the built-in `web-search`
extension (off by default). It adds two tools:

- `web_search`: a query and an optional `count` (1 to 10, default 5); returns a ranked
  list of results, each with title, URL and snippet.
- `web_fetch`: one public `http`/`https` URL; returns the page's title, final URL and
  readable text as markdown. HTML is converted locally, by the extension itself; plain
  text, JSON and XML pass through.

The search backend is chosen once, when pi loads the extension, from its environment.
The first variable that is set and not empty wins:

| Variable | Backend | Where a query goes |
| --- | --- | --- |
| `PI_SEARX_URL` | SearXNG at that URL (`search.searxUrl` or `search.local` sets it) | that instance only: no third party, no key |
| `TAVILY_API_KEY` | Tavily | Tavily, a third party, with your key |
| `BRAVE_API_KEY` | Brave Search | Brave, a third party, with your key |

With none set, both tools still exist: `web_search` answers with these setup
instructions, `web_fetch` works. A `PI_SEARX_URL` that is not a plain `http`/`https`
URL is an error, never a silent switch to Tavily or Brave.

The API keys are not Nix options (they would land in the world-readable store): export
them yourself, from a secret manager or your shell profile, before pi starts, and
restart pi after a change. No output or error message repeats a key.

Queries to SearXNG go over a direct connection: `HTTP_PROXY`, `HTTPS_PROXY`,
`ALL_PROXY` and the like are ignored, so a query for your own instance cannot end up at
a proxy. That connection follows at most 3 redirects within the instance's own origin
(a trailing slash, a path prefix); any other redirect is an error that names its
target, so set `PI_SEARX_URL` to the address the instance answers at. Tavily and Brave
are asked through the runtime's `fetch`, which may honour those variables. Result
titles, snippets and URLs are reduced to one line without control characters.

`web_fetch` contacts the target sites directly from this machine, without a proxy, so
they see its address. It refuses:

- every scheme but `http` and `https`, and URLs with `user:password@`;
- `localhost`, `*.localhost` and the cloud metadata names, and every loopback, private
  (RFC 1918, unique local `fc00::/7`), link-local (with the metadata address
  `169.254.169.254`), carrier-grade NAT, multicast, reserved or unspecified address,
  however it is written (decimal, hex, IPv4-mapped or -compatible IPv6) and however it
  is reached (DNS, a redirect). IPv6 prefixes that carry an IPv4 address are checked by
  that address (well-known NAT64 `64:ff9b::/96`, 6to4 `2002::/16`) or refused as a whole
  (local-use NAT64 `64:ff9b:1::/48`, Teredo `2001::/32`, SIIT `::ffff:0:0:0/96`). A
  NAT64 prefix that a network chooses for itself cannot be recognised: on such a network
  a public-looking IPv6 address can still reach a private IPv4 one. Every redirect hop
  is checked again, at most 5 are followed, and the connection goes only to the
  addresses that were checked: a second DNS answer cannot move it to a private one, and
  a connection that ends up at any other address is dropped as soon as it connects,
  before the request is written;
- bodies over 2 MiB (decompressed) or 4 MiB (as received, still compressed), and
  images, PDFs and other binary types; it renders no JavaScript. A call takes at most
  30 s (20 s per hop); HTML conversion stops at 256 KiB of markdown (ending with a
  `[truncated]` line), links resolve against a `<base href>` only up to 2 KiB and
  longer link URLs are left out, and the output is cut at 50 KiB or 2000 lines, with a
  note.

Children: the registry entry has `forChildren = true`, so the economics bridge gives
both tools to background child agents, which inherit pi's environment and with it the
backend. In the nono sandbox the pi profile does not block the network and sets no
proxy, so the tools work there as well; the guard above is what keeps `web_fetch` off
local and private addresses.

Without Nix, the package (`pi install git:…`, see Without Nix) includes
`extensions/web-search`, so both tools load: unlike the Nix option, which is off by
default, the package turns the extension on. Until a backend variable is set in pi's
environment, `web_search` answers with the setup instructions above. To leave it out,
for example because another extension already provides `web_search` (pi refuses a
second tool of the same name), filter it:

    "packages": [
      {
        "source": "git:github.com/GRBurst/pi-setup@<tag>",
        "extensions": ["!extensions/web-search/**"]
      }
    ]

Which extensions a child agent loads without Nix is up to whatever starts it; this
repository does not configure that.

## Local search without NixOS

`programs.pi.search.local` runs SearXNG on demand, on `127.0.0.1` only, for the built-in
`web_search` (see Web search) or any extension that reads `PI_SEARX_URL`. It needs Home
Manager but neither NixOS nor a systemd user session, so it works in a container; where
systemd exists it works the same:

```nix
programs.pi.search.local.enable = true; # port 8888, pkgs.searxng
```

- `search.searxUrl` then defaults to `http://127.0.0.1:8888`, exported as `PI_SEARX_URL`.
- `pi-searx-up` starts SearXNG in the background, in its own session, unless something
  answers `http://127.0.0.1:<port>/healthz`, and waits at most 20 s in all (lock and
  start; `PI_SEARX_WAIT` in the environment changes the cap). Its probe ignores
  `http_proxy`, `ALL_PROXY` and the like: this is loopback. It is idempotent and quiet when
  its own instance runs, and two at once start one instance (they take a lock; a second
  `pi` waits for the first one's SearXNG). Whatever else answers there (a NixOS SearXNG on
  the same port, say) is reused, not started; `pi-searx-up` says so on stderr and in the
  log once, not at every start. `pi-searx-down` takes the same lock, stops the instance
  `pi-searx-up` started and leaves any other alone.
- **Reusing a server is a trust decision.** pi sends its queries to whatever answers on the
  port and takes its results as they come: another local user who bound the port first
  could read the queries and feed the agent results of their choosing. The default is to
  reuse, because the NixOS SearXNG on the same port runs as another user. On a machine
  with other users set `search.local.reuseExisting = false`: `pi-searx-up` then fails with a
  message when the port is held by a server it did not start, and the `pi` aliases start
  pi without `PI_SEARX_URL`, so without search. (A less common `port` only lowers the
  odds; any user can bind a free one first.)
- The module sets `programs.aiSandbox.harnesses.pi.preStart`, ai-sandbox's pre-start hook.
  Every alias of the pi harness (`pi`, `pi_nono`, every variant and their `_nono` twins)
  sources it, outside the sandbox, before the sandboxed command: `pi-searx-up` (a failure
  costs web search, never pi), then `export PI_SEARX_URL`. There are no wrapper commands,
  and the aliases are ai-sandbox's own lines. With
  `programs.aiSandbox.isolation.enable = false` there is only `pi`. A `pi` you set in
  `programs.aiSandbox.extraAliases` is your text and runs no hook. The hook starts
  `pi-searx-up` with `TMPDIR` unset: pi's own per-CLI `TMPDIR` is writable by the sandboxed
  pi, and the SearXNG daemon outlives it. Another module's `preStart` for pi merges with
  this one (`lib.mkAfter` / `lib.mkBefore` order it).
- State lives in `$XDG_STATE_HOME/pi-searx` (default `~/.local/state/pi-searx`, mode 0700):
  `secret` (generated once, 0600, never in the store), `settings.yml` (0600, rendered at
  every start), `pid`, `log`, `source` (the template and executable of the running
  instance), `foreign` (marks a reported reused server) and `lock`. After a switch that changes the settings or the package,
  restart it with `pi-searx-down && pi-searx-up`; `pi-searx-up` reminds you.
- It runs until `pi-searx-down`, a reboot or the end of the container; the next `pi` starts
  it again.
- `search.local.settings` merges over upstream's defaults, their engines included, with
  the JSON format on and the limiter off. Choose engines there, for example
  `use_default_settings.engines.keep_only = [ "duckduckgo" "wikipedia" ];`. The bind
  address, the port and the secret are the module's; `search.formats` must keep `json`.
- SearXNG runs outside the sandbox. pi reaches it over loopback TCP: the pi pack's nono
  network policy does not block it and the namespace isolation has no network layer. Its
  state dir is no grant of the pi profile, so the agent cannot read the secret.
- Queries leave from this machine's address to the upstream engines. From a datacenter
  address some engines answer with CAPTCHAs or blocks.

## Checks

Run one at a time, each capped (see `AGENTS.md`):

    nix build .#checks.x86_64-linux.<name>

## Licence

MIT, see `LICENSE`. The patches under `patches/pi-actor-subagents` are derived from
that upstream and distributed under its licence, kept next to them as
`patches/pi-actor-subagents/LICENSE`; see `NOTICE`.
