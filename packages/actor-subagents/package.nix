# pi-actor-subagents with three local patches, applied in this order:
#
# - child-prompt: upstream builds every child with `systemPromptOverride`, and in pi a custom
#   system prompt drops the default `tools` and `rules` sections, where extensions'
#   promptGuidelines land. A child therefore got an extension's tools without its guidance. The
#   patch hands the agent preamble to pi as an append prompt instead, so the default sections stay.
# - spawn-policy: the stable `globalThis.__subagentsApi_v1` (api.ts) other extensions drive: a
#   spawn-policy hook (model, effort, brief, tools, tool guard), an optional `task` parameter,
#   neutral model wording, send/list, childSessionId on spawn events, and a grace period before a
#   child's transient error (a 429 under a retry extension) wakes its parent.
# - spawn-api (spawnPolicyApi 2): optional `api.spawn` and `api.kill` for a caller's own agents
#   (quiet: no notices to the parent, no roster entry, and only the API and the user act on the
#   agent: no agent, its spawner included, messages or controls it; no agent preamble in its
#   system prompt), per-child tools (`childTools`) and cwd from the policy, and tool guards that
#   may answer with a Promise. `version` stays 1.
#
# The derivation name and the patch file names are stable, so a consumer can recognise the
# patched build by its store path. A patch that no longer applies fails this build;
# checks/actor-subagents runs the upstream suite on it. The upstream licence (MIT) is
# ../../patches/pi-actor-subagents/LICENSE.
{
  applyPatches,
  src,
}:
(applyPatches {
  name = "pi-actor-subagents-patched";
  inherit src;
  patches = [
    ../../patches/pi-actor-subagents/pi-actor-subagents-child-prompt.patch
    ../../patches/pi-actor-subagents/pi-actor-subagents-spawn-policy.patch
    ../../patches/pi-actor-subagents/pi-actor-subagents-spawn-api.patch
  ];
}).overrideAttrs (old: {
  # The version of __subagentsApi_v1 this build provides, which consumers assert: 1 for the spawn
  # policy, 2 with the spawn-api patch. Through overrideAttrs: applyPatches refuses `passthru`.
  passthru = (old.passthru or {}) // {spawnPolicyApi = 2;};
})
