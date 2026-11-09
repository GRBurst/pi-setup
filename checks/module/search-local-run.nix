# The scripts of the on-demand SearXNG (`search.local`), run: the module's own pi-searx-up,
# pi-searx-down and pi_nono-with-search, over the real `pkgs.searxng`, inside the build
# sandbox (no network: /healthz and an empty JSON search on loopback only). Wired by
# ./default.nix as pi-setup-search-local-run.
{
  lib,
  pkgs,
  piLib,
}: let
  port = 48888;
  home = piLib.piFixtureWith {
    programs.pi.search.local = {
      enable = true;
      inherit port;
    };
  };
  pkg = n: lib.findFirst (p: p.name == n) (throw "search-local-run: no package ${n}") home.home.packages;
  # The same module with reuseExisting off (one state dir, so one instance, with the default's).
  strict = piLib.piFixtureWith {
    programs.pi.search.local = {
      enable = true;
      inherit port;
      reuseExisting = false;
    };
  };
  strictPkg = n: lib.findFirst (p: p.name == n) (throw "search-local-run: no strict package ${n}") strict.home.packages;
in
  pkgs.runCommand "pi-setup-search-local-run" {
    nativeBuildInputs =
      map pkg ["pi-searx-up" "pi-searx-down" "pi_nono-with-search"]
      ++ [pkgs.curl pkgs.jq pkgs.iproute2 pkgs.coreutils pkgs.gnugrep pkgs.python3 pkgs.util-linux];
    inherit port;
    strictUp = "${strictPkg "pi-searx-up"}/bin/pi-searx-up";
    strictWrapper = "${strictPkg "pi_nono-with-search"}/bin/pi_nono-with-search";
    profile = home.programs.aiSandbox.harnessProfiles.pi;
  } ''
    export HOME=$PWD/home XDG_STATE_HOME=$PWD/state
    # A proxy that refuses everything, in every spelling: loopback must not go through it,
    # or /healthz never answers (pi-searx-up's curl; the ones below say --noproxy too).
    export http_proxy=http://127.0.0.1:1 https_proxy=http://127.0.0.1:1 ALL_PROXY=http://127.0.0.1:1
    export HTTP_PROXY=$http_proxy HTTPS_PROXY=$http_proxy all_proxy=$ALL_PROXY
    unset no_proxy NO_PROXY
    mkdir -p "$HOME"
    state=$XDG_STATE_HOME/pi-searx
    url=http://127.0.0.1:$port
    fail() {
      echo "search-local-run: $*" >&2
      if [ -f "$state/log" ]; then tail -n 40 "$state/log" >&2; fi
      exit 1
    }
    answers() { curl --noproxy '*' -fsS -m 2 -o /dev/null "$url/healthz" 2>/dev/null; }
    # pi-searx-down returns when the port is free again, not when SearXNG is merely dying.
    portfree() { [ -z "$(ss -ltnH "sport = :$port")" ]; }
    mode() { stat -c %a "$1"; }

    # 1. A cold start, from an environment that tries to move the bind, the port and the secret.
    SEARXNG_BIND_ADDRESS=0.0.0.0 SEARXNG_PORT=1 SEARXNG_SECRET=ambient pi-searx-up >up1.out 2>up1.err \
      || fail "the first pi-searx-up failed: $(cat up1.err)"
    [ ! -s up1.out ] || fail "pi-searx-up wrote to stdout, which belongs to pi: $(cat up1.out)"
    grep -q "started SearXNG" up1.err || fail "the first pi-searx-up did not say it started SearXNG: $(cat up1.err)"
    grep -q "started SearXNG" "$state/log" || fail "the start is not in $state/log"
    answers || fail "nothing answers $url/healthz after pi-searx-up"
    code=$(curl --noproxy '*' -sS -m 60 -o result.json -w '%{http_code}' "$url/search?q=nixos&format=json")
    [ "$code" = 200 ] || fail "format=json answered HTTP $code (the JSON format must be on)"
    jq -e '.results | type == "array"' result.json >/dev/null || fail "format=json is not SearXNG's JSON: $(head -c 300 result.json)"
    listeners=$(ss -ltnH "sport = :$port" | awk '{print $4}' | sort -u)
    [ "$listeners" = "127.0.0.1:$port" ] || fail "SearXNG listens on '$listeners', not on 127.0.0.1:$port only"

    # The per-user secret: 0600 in a 0700 dir, rendered into a 0600 settings file, never the
    # placeholder and never the ambient SEARXNG_SECRET.
    [ "$(mode "$state")" = 700 ] || fail "$state is $(mode "$state"), not 700"
    [ "$(mode "$state/secret")" = 600 ] || fail "the secret is $(mode "$state/secret"), not 600"
    [ "$(mode "$state/settings.yml")" = 600 ] || fail "settings.yml is $(mode "$state/settings.yml"), not 600"
    secret=$(cat "$state/secret")
    [[ $secret =~ ^[0-9a-f]{64}$ ]] || fail "the secret is not 64 hex digits"
    grep -qF "$secret" "$state/settings.yml" || fail "settings.yml does not hold the secret"
    if grep -qF -e '@PI_SEARX_SECRET@' -e ambient "$state/settings.yml"; then fail "settings.yml holds the placeholder or the ambient secret"; fi
    pid=$(cat "$state/pid")

    # 2. Idempotent: a second call reuses the running instance, quietly, with the same secret.
    pi-searx-up 2>up2.err || fail "the second pi-searx-up failed: $(cat up2.err)"
    [ ! -s up2.err ] || fail "the second pi-searx-up was not quiet: $(cat up2.err)"
    [ "$(cat "$state/pid")" = "$pid" ] || fail "the second pi-searx-up started another SearXNG"
    [ "$(cat "$state/secret")" = "$secret" ] || fail "the second pi-searx-up changed the secret"

    # 3. pi-searx-down stops it; the secret stays for the next start.
    pi-searx-down 2>down.err || fail "pi-searx-down failed: $(cat down.err)"
    if answers; then fail "SearXNG still answers after pi-searx-down"; fi
    portfree || fail "the port is still held after pi-searx-down"
    [ ! -e "$state/pid" ] || fail "pi-searx-down left the pid file"
    [ "$(cat "$state/secret")" = "$secret" ] || fail "pi-searx-down changed the secret"

    # 3b. Two starts at once (two pi): one instance, both succeed, neither mistakes the other's
    #     start for a foreign server.
    before=$(grep -c "started SearXNG" "$state/log")
    pi-searx-up 2>c1.err &
    c1=$!
    pi-searx-up 2>c2.err &
    c2=$!
    wait "$c1" || fail "the first of two concurrent pi-searx-up failed: $(cat c1.err)"
    wait "$c2" || fail "the second of two concurrent pi-searx-up failed: $(cat c2.err)"
    [ "$(($(grep -c "started SearXNG" "$state/log") - before))" = 1 ] || fail "two concurrent pi-searx-up did not start exactly one SearXNG"
    if grep -q reusing "$state/log" c1.err c2.err; then fail "a concurrent pi-searx-up took the other's instance for a foreign one"; fi
    answers || fail "nothing answers after two concurrent pi-searx-up"
    [ -r "/proc/$(cat "$state/pid")/environ" ] || fail "the pid file names no running process after two concurrent pi-searx-up"

    # 3c. pi-searx-down takes the lock: it waits for a holder instead of racing it.
    ( flock 9; exec sleep 3 ) 9>>"$state/lock" &
    holder=$!
    sleep 0.5
    t=$(date +%s%N)
    pi-searx-down 2>down3.err || fail "pi-searx-down under a held lock failed: $(cat down3.err)"
    ms=$((($(date +%s%N) - t) / 1000000))
    [ "$ms" -ge 2000 ] || fail "pi-searx-down did not wait for the lock holder ($ms ms)"
    if answers; then fail "SearXNG still answers after pi-searx-down under a held lock"; fi
    wait "$holder"

    # 3d. The wait for a lock is capped by PI_SEARX_WAIT (default 20 s): it fails and says why.
    ( flock 9; exec sleep 60 ) 9>>"$state/lock" &
    holder=$!
    sleep 0.5
    start=$SECONDS
    if PI_SEARX_WAIT=3 pi-searx-up 2>wait.err; then fail "pi-searx-up succeeded while the lock was held"; fi
    [ $((SECONDS - start)) -lt 8 ] || fail "pi-searx-up waited $((SECONDS - start)) s for a lock, with PI_SEARX_WAIT=3"
    grep -q "holds" wait.err || fail "the lock timeout is not explained: $(cat wait.err)"
    kill "$holder"
    wait "$holder" 2>/dev/null || true

    # 4. The wrapper starts SearXNG before the sandboxed pi and passes the arguments and stdin
    #    through (a fake nono records what it got; the nono-only line needs no namespaces).
    mkdir fake
    cat >fake/nono <<'EOF'
    #!/bin/sh
    if curl --noproxy '*' -fsS -m 2 -o /dev/null "http://127.0.0.1:$port/healthz"; then echo "searx: up"; else echo "searx: down"; fi
    echo "PI_SEARX_URL=$PI_SEARX_URL"
    echo "argv: $*"
    echo "stdin: $(cat)"
    EOF
    chmod +x fake/nono
    echo prompt | PATH=$PWD/fake:$PATH pi_nono-with-search --version a\ b >wrapped.out 2>wrapped.err || fail "pi_nono-with-search failed: $(cat wrapped.err)"
    grep -qx "stdin: prompt" wrapped.out || fail "a prompt piped into the wrapper did not reach pi: $(cat wrapped.out)"
    grep -qx "searx: up" wrapped.out || fail "SearXNG did not answer when the wrapper ran nono: $(cat wrapped.out)"
    grep -qx "PI_SEARX_URL=$url" wrapped.out || fail "the wrapper did not export PI_SEARX_URL=$url"
    grep -qF "argv: run --profile $profile " wrapped.out || fail "the wrapper did not run nono with the pi profile: $(cat wrapped.out)"
    grep -qF -- "-- pi --version a b" wrapped.out || fail "the wrapper did not pass the arguments to pi: $(cat wrapped.out)"
    pi-searx-down 2>/dev/null
    portfree || fail "the port is still held after pi-searx-down of the wrapper's instance"

    # 5. Whatever already answers /healthz on the port is reused, logged as such, and left
    #    alone by pi-searx-down.
    mkdir www && echo OK >www/healthz
    python3 -m http.server --bind 127.0.0.1 --directory www "$port" >/dev/null 2>&1 &
    foreign=$!
    for _ in $(seq 1 50); do answers && break; sleep 0.1; done
    answers || fail "the foreign server did not come up"
    pi-searx-up 2>up3.err || fail "pi-searx-up failed beside a foreign instance: $(cat up3.err)"
    grep -q "reusing" up3.err || fail "pi-searx-up did not say it reuses the foreign instance: $(cat up3.err)"
    grep -q "reusing" "$state/log" || fail "the reuse is not in $state/log"
    pi-searx-up 2>up3b.err || fail "the second pi-searx-up beside a foreign instance failed: $(cat up3b.err)"
    [ ! -s up3b.err ] || fail "the reuse is reported at every start, not once: $(cat up3b.err)"
    [ "$(grep -c reusing "$state/log")" = 1 ] || fail "the reuse is logged more than once"
    [ ! -e "$state/pid" ] || fail "pi-searx-up wrote a pid file for an instance it did not start"
    pi-searx-down 2>down2.err || fail "pi-searx-down failed beside a foreign instance"
    grep -q "left alone" down2.err || fail "pi-searx-down did not say it leaves the foreign instance alone: $(cat down2.err)"
    answers || fail "pi-searx-down stopped an instance it did not start"

    # 5b. reuseExisting = false: the foreign server is refused (nothing started), and the
    #     wrapper starts pi without PI_SEARX_URL, whatever the caller had set.
    if "$strictUp" 2>up5.err; then fail "pi-searx-up with reuseExisting = false reused a foreign server"; fi
    grep -q "refusing" up5.err || fail "the refusal is not explained: $(cat up5.err)"
    [ ! -e "$state/pid" ] || fail "a refusal left a pid file"
    answers || fail "a refusal stopped the foreign server"
    PI_SEARX_URL=ambient PATH=$PWD/fake:$PATH "$strictWrapper" </dev/null >wrapped3.out 2>/dev/null || fail "the strict wrapper stopped pi on a refusal"
    grep -qx "PI_SEARX_URL=" wrapped3.out || fail "pi was given PI_SEARX_URL beside a refused server: $(cat wrapped3.out)"
    kill "$foreign"
    wait "$foreign" 2>/dev/null || true

    # 5c. Nothing on the port any more: the strict wrapper starts its own instance and exports
    #     the URL; that ends the foreign state (the next foreign server is reported again).
    portfree || fail "the port is held after the foreign server was killed"
    [ -e "$state/foreign" ] || fail "the foreign marker is gone before the foreign server was"
    PATH=$PWD/fake:$PATH "$strictWrapper" </dev/null >wrapped4.out 2>/dev/null || fail "the strict wrapper failed on a free port"
    grep -qx "searx: up" wrapped4.out || fail "the strict wrapper did not start SearXNG: $(cat wrapped4.out)"
    grep -qx "PI_SEARX_URL=$url" wrapped4.out || fail "the strict wrapper did not export the URL for its own instance"
    [ ! -e "$state/foreign" ] || fail "starting its own instance left the foreign marker"
    pi-searx-down 2>/dev/null
    portfree || fail "the port is still held after pi-searx-down of the strict wrapper's instance"

    # 6. A port taken by something that is no SearXNG: pi-searx-up fails fast and names the
    #    log, and the wrapper still starts pi.
    python3 -c 'import socket, time
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", '"$port"')); s.listen(1); time.sleep(600)' &
    blocker=$!
    for _ in $(seq 1 50); do [ -n "$(ss -ltnH "sport = :$port")" ] && break; sleep 0.1; done
    [ -n "$(ss -ltnH "sport = :$port")" ] || fail "the blocking listener did not come up: $(ss -ltnpa 2>&1 | head -20; jobs -l; kill -0 $blocker 2>&1)"
    start=$SECONDS
    if pi-searx-up 2>up4.err; then fail "pi-searx-up succeeded on a port held by another program"; fi
    [ $((SECONDS - start)) -lt 15 ] || fail "pi-searx-up took $((SECONDS - start)) s to give up on a dead start"
    grep -qF "$state/log" up4.err || fail "the failure does not name the log: $(cat up4.err)"
    [ ! -e "$state/pid" ] || fail "a failed start left the pid file"
    PATH=$PWD/fake:$PATH pi_nono-with-search </dev/null >wrapped2.out 2>/dev/null || fail "a failed pi-searx-up stopped the wrapper"
    grep -qx "searx: down" wrapped2.out || fail "the wrapper did not reach nono after a failed start"
    kill "$blocker"

    touch "$out"
  ''
