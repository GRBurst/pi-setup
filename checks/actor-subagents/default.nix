# The upstream test suite of the PATCHED pi-actor-subagents (the exact source
# <agentDir>/extensions/actor-subagents links to). A patch that no longer applies fails the
# package's build in applyPatches; a patch that applies but breaks the extension fails the suite.
#
# pi loads the extension uncompiled with type stripping, so node's own test runner is the whole
# toolchain. Upstream test files that import pi's peer dependencies
# (@earendil-works/pi-{ai,tui,coding-agent}, which only exist inside pi) are left out:
# agent-tools, panel and the pi-*.test.ts contract tests against the installed pi. Upstream's own
# modules import pi-tui at run time too since e92099a (panel-logic.ts: visibleWidth, reached
# from engine.test.ts), so the npm lock's node_modules (../npm) is linked in.
{
  pkgs,
  src,
  nodeModules,
}:
pkgs.runCommand "pi-actor-subagents-tests" {nativeBuildInputs = [pkgs.nodejs];} ''
  cp -r ${src} work
  chmod -R u+w work
  ln -s ${nodeModules}/node_modules work/node_modules
  cd work/extensions/actor-subagents
  export HOME=$TMPDIR/home
  mkdir -p "$HOME"
  find . -name '*.test.ts' ! -name agent-tools.test.ts ! -name panel.test.ts ! -name 'pi-*.test.ts' -print0 \
    | xargs -0 node --test --experimental-strip-types

  # The child-prompt patch's own test must be part of what ran, and index.ts must build the
  # child prompt through it rather than through a full override, which is what drops pi's tool
  # and rules sections.
  grep -q 'childPromptOptions' child-prompt.test.ts
  grep -q 'childPromptOptions(' index.ts
  if grep -q 'systemPromptOverride:' index.ts; then
    echo "index.ts still replaces the child's whole system prompt" >&2
    exit 1
  fi

  # The spawn-policy patch's tests must be part of what ran, and index.ts must publish the API,
  # route spawns through its policy and hold a child's error notice back in the grace gate.
  for t in api spawn-policy spawn-wording error-notice-gate settings-grace usage-line tool-guard; do
    test -f "$t.test.ts"
  done
  grep -q 'installApi(' index.ts
  grep -q '__subagentsApi_v1' api.ts
  grep -q 'spawnPolicy: () => api.spawnPolicy()' index.ts
  grep -q 'errorGate.onEngineEvent(e)' index.ts
  grep -q 'toolGuardExtensions(spec.toolGuard)' index.ts
  grep -q 'childToolAllowlist(spec.tools, customTools)' index.ts
  # Upstream's engine routes a terminal child error to its parent itself (Engine.announce); the
  # gate only works if the engine defers that to it and the gate hands the error back.
  grep -q 'engine.deferErrorNotices = true' index.ts
  grep -q 'engine.announceError(name, reason)' index.ts
  grep -q 'if (!this.deferErrorNotices) this.announceError' engine.ts
  if grep -q 'engine.subscribe(() => updateStatus())' index.ts; then
    echo "index.ts feeds engine events to the roster without the error-notice gate" >&2
    exit 1
  fi

  # The spawn-api patch's tests must be part of what ran, and index.ts must bind api.spawn/api.kill
  # (spawnPolicyApi 2: agents a caller spawns and kills through the API), start a child in the
  # policy's cwd with the policy's child tools, and keep quiet agents off the roster.
  for t in spawn-api child-tools quiet-control; do
    test -f "$t.test.ts"
  done
  # A quiet agent answers only to the API and the user; send_message asks the engine first.
  grep -qF 'engine.quietRefusal(selfName, t)' agent-tools.ts
  grep -qF 'd.engine.kill(API_ACTOR, names)' api.ts
  # A quiet child runs without the agent preamble (its handshake waits for a go-ahead no one sends).
  grep -qF 'childPromptOptions(spec.name, spec.systemPrompt, spec.spawnedBy, spec.quiet === true)' index.ts
  grep -q 'spawnApiDeps({ engine, spawnAgent' index.ts
  grep -q 'cwd = cwdOf(spec)' index.ts
  grep -qF '.map(piTool)' index.ts
  grep -qF 'persisted(engine.list())' index.ts

  touch $out
''
