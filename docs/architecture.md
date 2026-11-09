# Architecture

## What this repository is

The pi coding agent as a set of resources: pi extensions, the settings
seed, the pi-web package and its helper scripts. It is a pi package (installable
without Nix with `pi install`) and a Home Manager module (`programs.pi`) for users
of Nix. Nix is first-class: the module's extension registry is the source for the
package manifest and the settings seed, so both routes ship the same resource set.

## Boundaries

- Inputs: `nixpkgs` and `home-manager` (for the checks), the sandbox repository
  `ai-sandbox` (its Home Manager module and the isolation wrapper), and three
  extension sources pinned to revisions. Consumers `follows` their own inputs.
- The repository imports no private layer and names none: a module that needs
  more declares an option, and the layer above sets it. Other layers import this
  one; there is no back edge.
- The modules read no `osConfig`, no host option namespace and set no firewall
  option. Service ports are documented in the README, never opened.
- No private data: the `leaks` check scans the source for generic personal-data
  patterns, and its scanner is self-tested on fixtures; commit messages follow
  the rule in AGENTS.md.
- Option names and the module keys (`pi-setup#pi`, `pi-setup#homeModules.default`)
  are a public contract.
- Generated files are written only by `nix run .#render`; `boundary` enforces
  the text rule for the modules and packages, and evaluates the modules, the
  render fixture and the render tree from a copy without the rendered paths
  (none of them reads a rendered file).

## Layout

```
flake.nix flake.lock README.md AGENTS.md docs/architecture.md
package.json                      the pi package manifest (rendered)
settings/seed.json                the settings seed (rendered)
render/                           the render fixture and `nix run .#render`
modules/home-manager/             the Home Manager module (pi options, extension registry)
modules/home-manager/economics-bridge.nix  the economics bridge (a path output)
extensions/                       the extensions this repository carries (`static-working-indicator`, `web-search`)
packages/pi-web/                  the pi-web package (Nix-only service)
examples/existing-flake/          the example flake for an existing Home Manager flake (README, `existing-flake-example`)
scripts/                          the two helper scripts (kept byte-stable; covered by `agent-web-prune` and as `writeShellApplication`)
checks/                           module/ (behaviour), render, package, leaks, meta checks, web-search/ (the extension's tests)
```

## Resources and render

- Extensions are declared in the registry of the module and linked by
  Home Manager, or forwarded through the bridge.
- `package.json` (the `pi` manifest and the `dependencies` of the extensions) and
  `settings/seed.json` are rendered from a render fixture of the module and
  compared by `render-*` checks. A hand edit fails the check; the render throws on
  a registry entry it cannot map to a package path.
- Without Nix, `pi install git:<repository>@<ref>` installs the package; a local
  checkout needs `npm install --omit=dev --legacy-peer-deps` first, then
  `pi install ./<checkout>`. pi owns install, update, removal and `settings.json`.

## Decision register

These entries are this repository's own decisions, stated without references to
any other repository.

- **AD1 Nix renders, plain files ship.** Every non-Nix artifact with a Nix
  counterpart is the evaluated output of a render fixture, committed, and checked.
- **AD2 One resource set.** The registry is the single list of resources; the
  package manifest and the seed derive from it.
- **AD3 Pi package route.** The repository root is a pi package (`"private"` and a
  `pi` manifest, no installer, no `Makefile`); the keyword `pi-package` marks it
  for discovery.
- **AD4 Pinned extension inputs.** Extension sources carry their revision in the
  URL, equal to the revisions the Nix side locks; a plain lock update would
  break the equality of the two routes.
- **AD5 No leak terms.** The repository contains no private layer names and no
  host paths; the scanner's term list is public and short.
- **AD6 Commits name no host, plan or task.** Commit messages and tracked files
  stay neutral because the history becomes public.
- **AD7 Settings are pi's file without Nix.** The module may link or seed the
  settings file; without Nix pi owns it, and the README says how to merge the seed.
- **AD8 Nix-only parts are documented.** The sandbox, the pi-web service, the
  economics bridge and the Claude login helper are Nix-only, and the README states it.
- **AD9 Config-dir wiring is off by default.** The Claude login helper and its
  config-dir variable are enabled by an option, because the unpatched extension
  reads `~/.claude`.
- **AD10 No shipped profiles.** The repository ships no profile directories; the
  shared profile of the sandbox is the sandbox repository's.
- **AD11 Smoke tests load the package.** The install smoke check runs pi with no
  API key and expects the missing-key message; with every manifest path present,
  this proves that each extension loads without error.
- **AD12 Layout by role.** Module files sit under `modules/`, each package under
  `packages/<name>/`, checks under `checks/`; file names describe the role, never
  another repository.
- **AD13 Module wiring.** `homeModules.default` is the module tree; `homeModules.piEconomics`
  is a path to the bridge file, not a value, so the module's dedup key stays stable.
  The layer above sets the bridge's options; nothing here reads its configuration.
- **AD14 Package resources from upstream.** Extension packages are npm dependencies
  pinned to the locked revisions of their upstream repositories and referenced as
  `./node_modules/<package>/<subpath>`, pi's documented route for packages used by a
  package. The `claude-auth` dependency is the unpatched upstream.
- **AD15 Login helper caveat.** The Claude login helper is Nix-only and has no
  one-liner without Nix. The unpatched `claude-auth` reads and locks `~/.claude`,
  which nono leaves read-only, so token refresh inside the sandbox fails. Turn it
  off (`programs.pi.claudeAuth.enable = false`, or filter it out with the settings
  object form), or wait for upstream config-dir support. Do not grant the sandbox
  write access to `~/.claude`: an agent could then write Claude Code settings or
  hooks that an unsandboxed `claude` runs.
- **AD16 Patches stay out.** A patched `claude-auth` build is not in this repository;
  the Nix option `programs.pi.claudeAuth.package` (default: the unpatched source)
  selects which build is used.
- **AD17 One lock fact, one check.** The manifest and the seed are rendered from
  `flake.lock`, so a changed revision turns the render check red; no second check
  over the same facts is kept.
- **AD18 Own extensions stand alone.** An extension of this repository imports nothing
  beyond pi, `typebox` and Node's built-ins, and only its `index.ts` imports pi or
  `typebox`; the rest runs under plain `node --test`. `web-search` therefore converts HTML
  with its own tolerant parser and opens its connections itself, pinned to the addresses
  its guard checked, instead of adding an npm dependency or a proxy. Its check runs the
  same tests under `bun test` as well: the pi package this flake builds against runs on
  Node, the standalone pi binaries on Bun, and the two differ where the guard and the
  converter depend on them (`lookup`, proxies, zlib, string limits).
