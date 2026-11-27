# What pi does with a request that a provider hook holds while the turn stops. The actor's
# request hooks rely on it: an extension's `before_provider_request` handler may await a
# long-running decision, and when the turn stops meanwhile (`ctx.abort()`, as pause, kill and
# Esc do), pi must not send the held request once the handler returns.
#
# pi runs offline against a fake provider on localhost (./probe.mjs, also the extension that holds
# the request), over both transports the hooks meet: openai-completions and anthropic-messages
# (a custom provider, not api.anthropic.com, so no message threads). Per pi and transport:
# - control run: the hook holds and returns, the turn does not stop: the request reaches the server;
# - abort run: the hook stops the turn: (i) `ctx.signal` aborts and (ii) the server receives nothing.
# Every miss is reported; any miss fails. Each pi asserts the version it runs.
{
  pkgs,
  lib,
  # [{pi, version}]: the pi packages to run and the version each must report.
  pis,
}: let
  runs =
    lib.concatMapStrings (p: ''
      check_pi ${p.pi}/bin/pi ${lib.escapeShellArg p.version}
    '')
    pis;
in
  pkgs.runCommand "pi-request-abort" {nativeBuildInputs = [pkgs.nodejs pkgs.jq pkgs.coreutils];} ''
    export HOME=$PWD/home PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
    mkdir -p "$HOME"
    failed=0
    miss() {
      echo "pi-request-abort: $*" >&2
      failed=1
    }

    # one pi run against a fresh fake provider: run <pi> <model> <mode> <dir>
    run() {
      local pi=$1 model=$2 mode=$3 dir=$4 port server
      mkdir -p "$dir/agent"
      : >"$dir/server.jsonl"
      : >"$dir/probe.jsonl"
      SERVER_OUT=$dir/server.jsonl node ${./probe.mjs} serve "$dir/port" &
      server=$!
      for _ in $(seq 100); do [ -s "$dir/port" ] && break; sleep 0.1; done
      port=$(cat "$dir/port")
      jq -n --arg port "$port" '{providers: {
        "probe-openai": {baseUrl: "http://localhost:\($port)/v1", api: "openai-completions", apiKey: "x", models: [{id: "m"}]},
        "probe-anthropic": {baseUrl: "http://localhost:\($port)", api: "anthropic-messages", apiKey: "x", models: [{id: "m"}]}
      }}' >"$dir/agent/models.json"
      PI_CODING_AGENT_DIR=$dir/agent PROBE_OUT=$dir/probe.jsonl PROBE_MODE=$mode \
        timeout 120 "$pi" -p x --no-session -e ${./probe.mjs} --model "$model" </dev/null >"$dir/pi.log" 2>&1 || true
      kill "$server" 2>/dev/null || true
      wait "$server" 2>/dev/null || true
    }

    check_pi() {
      local pi=$1 version=$2 got t dir
      got=$("$pi" --version 2>&1 | tail -n 1)
      [ "$got" = "$version" ] || miss "expected pi $version, runs '$got'"
      for t in openai anthropic; do
        dir=runs/$version-$t-control
        run "$pi" "probe-$t/m" control "$dir"
        echo "pi $version $t control: server $(wc -l <"$dir/server.jsonl") request(s), pi said: $(tr '\n' ' ' <"$dir/pi.log")"
        if [ ! -s "$dir/server.jsonl" ]; then
          miss "pi $version $t: control: the request did not reach the server"
          cat "$dir/pi.log" >&2
        fi

        dir=runs/$version-$t-abort
        run "$pi" "probe-$t/m" abort "$dir"
        echo "pi $version $t abort: probe $(jq -c . "$dir/probe.jsonl" | tr '\n' ' ')server $(wc -l <"$dir/server.jsonl") request(s)"
        if ! jq -se 'any(.[]; .aborted == true)' "$dir/probe.jsonl" >/dev/null; then
          miss "pi $version $t: (i) ctx.signal did not abort"
          cat "$dir/pi.log" >&2
        fi
        if [ -s "$dir/server.jsonl" ]; then
          miss "pi $version $t: (ii) the aborted request reached the server"
          cat "$dir/pi.log" >&2
        fi
      done
    }

    ${runs}
    [ "$failed" = 0 ] || exit 1
    touch $out
  ''
