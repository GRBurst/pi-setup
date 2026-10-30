{
  lib,
  runCommand,
  writeShellApplication,
  jq,
  coreutils,
}: let
  script = writeShellApplication {
    name = "pi-web-prune-settings";
    runtimeInputs = [jq coreutils];
    text =
      builtins.readFile
      ../../scripts/pi-web-prune-settings.sh;
  };
in
  runCommand "agent-web-prune" {
    nativeBuildInputs = [script jq coreutils];
    meta.description = "pi-web settings.json prune: drops dangling store entries and nothing else";
  } ''
    set -euo pipefail

    fail() { echo "FAIL: $1" >&2; exit 1; }

    agent=$PWD/agent
    mkdir -p "$agent"
    live="$agent/live-package"
    mkdir -p "$live"

    export PI_WEB_SETTINGS="$agent/settings.json"

    # --- the regression this check exists for ------------------------------
    # A `$drop | index(.)` written without binding the entry makes jq search
    # the drop-list inside itself, which matches, which drops EVERY string --
    # silently deleting pi's own package list.
    cat > "$PI_WEB_SETTINGS" <<EOF
    {
      "packages": [
        "../../../../nix/store/gone-0.0.0/relays",
        {"source": "/an/object"},
        "live-package",
        "npm:pi-claude-auth"
      ],
      "otherKey": {"must": "survive"}
    }
    EOF

    pi-web-prune-settings

    got=$(jq -c '.packages' "$PI_WEB_SETTINGS")
    want='[{"source":"/an/object"},"live-package","npm:pi-claude-auth"]'
    [ "$got" = "$want" ] || fail "expected $want, got $got"

    # Order is a property, not a coincidence: pi loads packages in list order.
    [ "$(jq -r '.packages[1]' "$PI_WEB_SETTINGS")" = live-package ] \
      || fail "surviving entries must keep their original order"

    # Nothing outside .packages may be touched.
    [ "$(jq -r '.otherKey.must' "$PI_WEB_SETTINGS")" = survive ] \
      || fail "unrelated keys must be preserved"

    # --- idempotence -------------------------------------------------------
    pi-web-prune-settings
    [ "$(jq -c '.packages' "$PI_WEB_SETTINGS")" = "$want" ] \
      || fail "a second run must be a no-op"

    # --- a healthy file is left byte-identical -----------------------------
    # The common case is nothing to drop, and the file has two other writers,
    # so the script must not rewrite it at all then.
    before=$(sha256sum "$PI_WEB_SETTINGS" | cut -d' ' -f1)
    pi-web-prune-settings
    after=$(sha256sum "$PI_WEB_SETTINGS" | cut -d' ' -f1)
    [ "$before" = "$after" ] || fail "a file with nothing to drop must not be rewritten"

    # --- non-store paths are never touched ---------------------------------
    # Only this feature's own store entries are in scope; a user's relative or
    # absolute path that happens to be missing is not ours to remove.
    cat > "$PI_WEB_SETTINGS" <<EOF
    {"packages": ["/opt/someone/not-a-store-path", "../relative/missing"]}
    EOF
    pi-web-prune-settings
    [ "$(jq -c '.packages | length' "$PI_WEB_SETTINGS")" = 2 ] \
      || fail "non-store entries must never be pruned, even when missing"

    # --- a missing settings file is not an error ---------------------------
    rm -f "$PI_WEB_SETTINGS"
    pi-web-prune-settings || fail "a missing settings.json must exit 0"

    touch $out
  ''
