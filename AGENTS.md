# pi-setup: rules for agents

Public repository. Never write personal data into a tracked file: no host
names, no e-mail addresses (except `example.*` domains), no key ids, no
`/home/<name>` paths (fixture users `coder`, `tester`, `ai-test`, `u` are
allowed), no RFC 1918 addresses, no ssh-scheme remote URLs. The `leaks` check
enforces this. Commit messages and tracked files name no plan, task or spec
ids and no host; commits are authored as the public GitHub identity `GRBurst`
(noreply address).

The `ai-sandbox` input is `github:GRBurst/ai-sandbox`. Reviewed exceptions to
the `leaks` check go only in `checks/leaks/expected.txt`; do not add
`leak-scan: expected` markers.

Layering: this repo imports only `ai-sandbox`. Nothing here may name or import
the private layer; that layer imports this repo, never the reverse.

## Check lanes

Checks are grouped by what they guard (`checks/default.nix` merges the sets as
a disjoint union; a duplicate check name is an evaluation error):

- module: behaviour of the Home Manager module against fixture users
  (`settings`, `claude-auth`, `extensions`, `search`, `search-local`,
  `search-local-run`, `web`, `fixtures`,
  `agent-web-prune`, `actor-subagents-module`);
- render: committed non-Nix artifacts equal the Nix output (`render-seed`,
  `render-package`), and a Nix-only extension never reaches them (`render-nix-only`);
- package: the pi package installs and loads (`pi-package-manifest`,
  `pi-install-smoke`, `existing-flake-example`);
- extension: extension code under `node --test`, offline: the repository's own
  (`web-search`) and the patched actor-subagents' upstream suite (`actor-subagents`),
  its type check (`typecheck-actor-subagents`) and their toolchain (`npm-deps`,
  `typecheck-harness`);
- shell: `shellcheck` and the workflow lint (`actionlint`);
- meta: README and docs against the code, the leak scan, formatting,
  `readme-options`, `readme-sections`, `doc-refs`, `boundary` (no host coupling,
  no read of a rendered path).

`shellcheck` takes an explicit file list: every tracked `*.sh` must be in
exactly one of `checked` and `excluded` in `checks/shellcheck.nix`.

## Render rule

Only `nix run .#render` writes `package.json` and `settings/seed.json`; never edit
them by hand. The `render-*` checks diff the committed files against the Nix output.

## Commands

Nix state in the agent sandbox (the default cache is not granted):

    export XDG_CACHE_HOME=$HOME/.cache/pi/nixcache XDG_DATA_HOME=$HOME/.cache/pi/nixdata

The flake is read through git: `git add` a new file before building. Commits
are unsigned: `git -c commit.gpgsign=false commit`.

Checks, one capped `nix build` each. Never run `nix flake check` (it evaluates
every check in one process and is not capped):

    F=git+file://$PWD o=(--option eval-cache false) cap=$((20 * 1024 * 1024))
    names=$( (ulimit -v $cap && exec timeout -s KILL 300 nix eval --json "$F#checks.x86_64-linux" --apply builtins.attrNames "${o[@]}") ) &&
      names=$(jq -er '.[]' <<<"$names") || echo "LISTING FAILED"
    for c in $names; do
      (ulimit -v $cap && exec timeout -s KILL 900 nix build --no-link -L "$F#checks.x86_64-linux.$c" "${o[@]}") || echo "FAILED $c"
    done

Formatter: `nix build "$F#formatter.x86_64-linux" --no-link --print-out-paths`,
then `<out>/bin/alejandra <files>`.

## Rules

- Every new check is seen red once on a planted violation before it counts.
- Checks are a disjoint union (`checks/default.nix`): a duplicate name fails.
- Every tracked `*.sh` is listed in `checks/shellcheck.nix` as checked or
  excluded, never neither or both.
- Lock updates are separate commits. After `ai-sandbox` changes, relock
  this repo (`nix flake lock --update-input ai-sandbox`).
- Option names and the module keys (`pi-setup#pi`, `pi-setup#homeModules.default`)
  are a public contract.
- A pi package: never `@earendil-works/*` or `typebox` in `dependencies`
  (they are peers).
- A patched upstream lives in `patches/<input>/` with the upstream's `LICENSE`
  beside it and a section in `NOTICE`; the derivation name stays stable. Its
  patch texts follow the id rule above (no plan, task or review ids).
