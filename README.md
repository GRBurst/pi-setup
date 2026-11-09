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
unpatched upstream); `claudeAuth.setConfigDir` (default `false`) moves pi's Claude
config dir and needs a `package` that honours `CLAUDE_CONFIG_DIR`. The economics
bridge `homeModules.piEconomics` is a module path: a layer that declares
`programs.piEconomics` imports it, and it forwards `programs.pi`'s extension
registry, settings file and local health URL to `programs.piEconomics`.

The Nix side has the same `claude-auth` caveat as the package: with the default
unpatched `claudeAuth.package`, set `programs.pi.claudeAuth.enable = false` or wait for
upstream's config-dir support, and never grant the sandbox write access to `~/.claude`
(see the caveat under Without Nix).

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

**claude-auth caveat.** The package's `claude-auth` is the unpatched upstream
extension. Under nono it reads and locks `~/.claude`, which the pi profile does not
make writable, so token refresh fails in the sandbox. Turn it off with the object
form above, or wait for upstream's config-dir support.
Do not grant the sandbox write access to `~/.claude`: an agent could then write Claude
Code settings or hooks that an unsandboxed `claude` runs.

Nix-only (no `pi install` equivalent): the sandbox (`programs.aiSandbox`), the pi-web
service (`programs.pi.web`), the local SearXNG (`programs.pi.search.local`), the
economics bridge (`homeModules.piEconomics`), the
patched `claude-auth` with `claudeAuth.setConfigDir` and the `pi-claude-login` helper,
and the settings link, seed and reclaim that `settings.manage` controls. The sandbox
itself does not need Nix: without Nix, install ai-sandbox with its own installer
(`scripts/install.sh install`); its `pi` profile runs this package.

## Outputs

- `homeModules.default`: imports `ai-sandbox`'s module and `programs.pi`
  (key `pi-setup#homeModules.default`). Importing it alone is enough.
- `homeModules.piEconomics`: the economics bridge, a module path. A module that
  declares `programs.piEconomics` imports it; it forwards the extension registry,
  the settings file and the task-router settings to that module.
- `packages.<system>.pi-web`: the pi-web web UI package; the service is
  `programs.pi.web` (Nix-only).
- `apps.<system>.render`: `nix run .#render` writes `package.json` and
  `settings/seed.json` into the checkout.
- `legacyPackages.<system>.render-tree`: the rendered tree, built on its own.
- `checks.<system>`: `formatting`, `leaks`, `readme-options`, the module checks
  `settings`, `claude-auth`, `extensions`, `search`, `search-local`,
  `search-local-run`, `web`, `fixtures`,
  `shellcheck`, `actionlint`, `doc-refs`, `boundary`, `agent-web-prune`,
  `render-seed`, `render-package`, `pi-package-manifest`, `pi-install-smoke`,
  `readme-sections`, `existing-flake-example`.
- `formatter.<system>`: Alejandra.

Inputs: `nixpkgs`, `home-manager` (both followed by consumers),
`ai-sandbox`, and the extension sources `pi-question`, `pi-session-name` and
`pi-claude-auth` (pinned by revision in the URL, `flake = false`).
The `ai-sandbox` input is `github:GRBurst/ai-sandbox`.

## Options

All under `programs.pi`. The check `readme-options` keeps the option names in this
table and the option tree in step; it does not check the defaults. A `—` in the Default column means the option is required,
no default. `extensions.<name>.*` describes one registry entry.

| Option | Default | Meaning |
| --- | --- | --- |
| `agentDir` | `".pi/agent"` | pi's agent dir, relative to the home directory (`PI_CODING_AGENT_DIR`). |
| `builtinExtensions.question.enable` | `true` | Link the `question` extension: a question tool in a bottom dock, withheld from children. |
| `builtinExtensions.sessionName.enable` | `true` | Link the `session-name` extension: names the session so the tab title, selector and footer show what is worked on. |
| `builtinExtensions.staticWorkingIndicator.enable` | `false` | Link `static-working-indicator`, which replaces pi's animated working spinner with a static glyph (no timer, no repaint of the transcript). |
| `claudeAuth.credentialsFile` | read-only | Absolute path of the Claude credentials file the extension reads, for consumers outside the sandbox: `<dir>/.credentials.json` with `setConfigDir`, else `~/.claude/.credentials.json`. |
| `claudeAuth.dir` | `"$HOME/.pi/claude"` | The Claude config dir inside every pi sandbox (`CLAUDE_CONFIG_DIR`), used only with `setConfigDir`: absolute or starting with `$HOME/`. Under `$HOME/.pi` the pi pack's grant covers it; elsewhere it is granted read+write to every profile that extends the pack. |
| `claudeAuth.enable` | `true` | The `claude-auth` extension (Claude subscription auth for pi) and, with `setConfigDir`, pi's own Claude dir. |
| `claudeAuth.login.enable` | `true` | `pi-claude-login`, the one-time `claude auth login` into `dir`, run inside the pi sandbox; needs `setConfigDir`, the sandbox and its pi harness. |
| `claudeAuth.package` | the unpatched upstream | The tree whose `src/` pi loads as `claude-auth`. The default is the extension's own upstream source, unpatched; a layer may set a build that honours `CLAUDE_CONFIG_DIR`. Only the link moves: the key, the children policy and the existence check stay. |
| `claudeAuth.setConfigDir` | `false` | Wire pi's Claude dir: `CLAUDE_CONFIG_DIR = dir` on every profile that extends the pi pack, the grant for a dir outside `$HOME/.pi`, its creation at activation and `pi-claude-login`. Off by default because the unpatched upstream ignores `CLAUDE_CONFIG_DIR`: it reads and locks `~/.claude`, which nono leaves read-only. Turn it on only with a `package` that honours the variable. |
| `enable` | `false` | The pi coding agent: its settings file, extensions and services, inside the sandbox. |
| `extensions.<name>.checkPath` | the entry's `path` | What the existence assertion probes; set it when `path` is a derivation, so the check needs no build. |
| `extensions.<name>.description` | — | What the extension does. |
| `extensions.<name>.forChildren` | — | Whether background child agents load the extension (read by the economics bridge). |
| `extensions.<name>.input` | `null` | Where the extension comes from; the existence assertion names it. |
| `extensions.<name>.path` | — | The extension's directory, which `<agentDir>/extensions/<name>` links to. |
| `linkExtensions` | `true` | Link the registry and assert its entries exist. The economics bridge sets it to `false` and forwards the registry. |
| `package` | `null` | The pi package, installed when non-null (a consumer may install pi itself). |
| `router.localHealthUrl` | `null` | Health URL of the local model's server, set as the task router's `qwen-local` health by the economics bridge; `null` leaves the router settings alone. |
| `search.local.enable` | `false` | An on-demand SearXNG on `127.0.0.1` without NixOS or systemd: `pi-searx-up`, `pi-searx-down`, and the `pi`/`pi_nono` aliases starting it first (see Local search without NixOS). Sets `search.searxUrl` (mkDefault) to `http://127.0.0.1:<port>`. |
| `search.local.package` | `pkgs.searxng` | The SearXNG package; its main program serves the rendered settings. |
| `search.local.port` | `8888` | Loopback port. Whatever already answers `/healthz` there is reused instead of started (logged as such) and left alone by `pi-searx-down`; see `reuseExisting`. |
| `search.local.reuseExisting` | `true` | Reuse a server on the port that `pi-searx-up` did not start. A trust decision, see Local search without NixOS. `false`: `pi-searx-up` fails when it finds one, and the `pi` wrappers start pi without `PI_SEARX_URL`, so without search. |
| `search.local.settings` | `{ }` | SearXNG settings merged key by key over the base: upstream defaults with their engines (`use_default_settings = true`), limiter off, `search.formats = [ "html" "json" ]`. `search.formats` must keep `json`; `server.bind_address` (`127.0.0.1`), `server.port` and `server.secret_key` (per user, at the first start) are the module's. |
| `search.searxUrl` | `null`; `http://127.0.0.1:<port>` with `search.local.enable` | The SearXNG instance for a web-search extension that reads `PI_SEARX_URL` (none ships with this repository), exported as that variable; `null` sets no variable. Derive it from the instance that actually runs, never from a literal. |
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

## Local search without NixOS

`programs.pi.search.local` runs SearXNG on demand, on `127.0.0.1` only, for a web-search
extension that reads `PI_SEARX_URL` (none ships with this repository). It needs Home
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
  message when the port is held by a server it did not start, and the `pi` wrappers start
  pi without `PI_SEARX_URL`, so without search. (A less common `port` only lowers the
  odds; any user can bind a free one first.)
- The `pi` and `pi_nono` aliases run `pi-with-search` and `pi_nono-with-search`:
  `pi-searx-up` first (a failure costs web search, never pi), then the alias's usual
  sandboxed command. With `programs.aiSandbox.isolation.enable = false` there is only
  `pi`. A `pi` you set in `programs.aiSandbox.extraAliases` wins; other aliases of the pi
  harness (variants) do not start it, so run `pi-searx-up` before them.
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

MIT, see `LICENSE`.
