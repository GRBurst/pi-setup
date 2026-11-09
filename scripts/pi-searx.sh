# shellcheck shell=bash
#
# The on-demand SearXNG of `programs.pi.search.local`: `pi-searx-up` and `pi-searx-down`
# (PI_SEARX_ACTION up or down). No systemd: a background process in its own session,
# started when nothing answers on the loopback port and stopped only by pi-searx-down.
#
# Set by the module before this text:
#   PI_SEARX_ACTION    up | down
#   PI_SEARX_PORT      the loopback port
#   PI_SEARX_TEMPLATE  the settings.yml in the store; its secret_key is the placeholder
#                      @PI_SEARX_SECRET@, replaced here by the per-user secret
#   PI_SEARX_RUN       the SearXNG executable (searxng-run)
#   PI_SEARX_REUSE     1: reuse whatever else answers on the port; 0: refuse it (up fails)
# Optional from the caller:
#   PI_SEARX_WAIT      seconds (default 20): the cap on lock wait plus start wait together
#
# State (dir 0700): $XDG_STATE_HOME/pi-searx/ (default ~/.local/state/pi-searx/) holds
# `secret` (0600, generated once), `settings.yml` (0600, rendered at every start), `pid`,
# `log` (SearXNG's output and one line per start, reuse and failure), `source` (the
# template and executable of the running instance), `foreign` (exists while the last up
# found an instance it did not start, so that reuse is reported once) and `lock` (held by
# up and down while they act: one at a time).
#
# up: exit 0 when an instance answers /healthz (started now, already running, or one that
# pi-searx-up did not start, which is reused and reported as such, once); 1 when it did not
# come up within PI_SEARX_WAIT (20) s, lock wait included, or when it refuses an instance it
# did not start (PI_SEARX_REUSE=0). Quiet when its own instance already runs.
# down: stops the instance pi-searx-up started; one it did not start is left alone.

: "${PI_SEARX_ACTION:?}" "${PI_SEARX_PORT:?}" "${PI_SEARX_TEMPLATE:?}" "${PI_SEARX_RUN:?}" "${PI_SEARX_REUSE:?}"
budget=${PI_SEARX_WAIT:-20}
[[ $budget =~ ^[0-9]+$ ]] || budget=20
t0=$SECONDS
url="http://127.0.0.1:$PI_SEARX_PORT"
state="${XDG_STATE_HOME:-$HOME/.local/state}/pi-searx"
log="$state/log"
settings="$state/settings.yml"
me="pi-searx-$PI_SEARX_ACTION"

say() { # say MESSAGE: to stderr and, with a timestamp, to the log
  printf '%s: %s\n' "$me" "$1" >&2
  printf '%s %s: %s\n' "$(date -Is)" "$me" "$1" >>"$log"
}

listening() { (exec 3<>"/dev/tcp/127.0.0.1/$PI_SEARX_PORT") 2>/dev/null; }

# alive PID: the process still runs. A zombie whose threads are gone holds no port, but the
# leader of a process that exited its main thread first (a handled SIGTERM) can still hold it.
alive() {
  kill -0 "$1" 2>/dev/null || return 1
  ! { grep -q '^State:[[:space:]]*Z' "/proc/$1/status" 2>/dev/null && ! listening; }
}

# No proxy, whatever the environment says (http_proxy, ALL_PROXY, a .curlrc): this is loopback.
answers() { curl -q --noproxy '*' -fsS -m 2 -o /dev/null "$url/healthz" 2>/dev/null; }

# ours PID: PID is the SearXNG started from this state dir. Its environment names this
# settings file; a stale pid file naming a reused PID, or a zombie (no environment), is not.
ours() {
  [ -n "$1" ] && [ -r "/proc/$1/environ" ] &&
    tr '\0' '\n' <"/proc/$1/environ" | grep -xF -- "SEARXNG_SETTINGS_PATH=$settings" >/dev/null
}

case $PI_SEARX_ACTION in
up | down) ;;
*)
  echo "pi-searx: unknown action $PI_SEARX_ACTION" >&2
  exit 2
  ;;
esac

# shellcheck disable=SC2174 # -m is for the state dir; its parents are the user's own
mkdir -p -m 700 "$state"
chmod 700 "$state" # a dir that already existed

# One up or down at a time, within one budget for lock and start: a second pi waits for the
# first one's instance instead of racing it for the port, and down does not pull the
# instance from under a start. The pid is read only now, under the lock: what the lock's
# previous holder started is what this one sees.
exec 9>>"$state/lock"
flock -w "$budget" 9 || {
  say "another pi-searx holds $state/lock after $budget s"
  exit 1
}
pid=$(cat "$state/pid" 2>/dev/null || true)

if [ "$PI_SEARX_ACTION" = down ]; then
  if ours "$pid"; then
    kill "$pid" 2>/dev/null || true
    # Until it is gone, not only until it is no longer recognisably ours (a process that is
    # exiting has no readable environment while its port is still open).
    for ((i = 0; i < 50; i++)); do
      alive "$pid" || break
      sleep 0.1
    done
    if alive "$pid" && ours "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
      for ((i = 0; i < 20; i++)); do
        alive "$pid" || break
        sleep 0.1
      done
    fi
    rm -f "$state/pid"
    say "stopped SearXNG (pid $pid) on $url"
  else
    rm -f "$state/pid"
    if answers; then
      say "the SearXNG on $url was not started by pi-searx-up; left alone"
    else
      say "not running"
    fi
  fi
  exit 0
fi

if answers; then
  if ours "$pid"; then
    rm -f "$state/foreign"
    if [ "$(cat "$state/source" 2>/dev/null)" != "$PI_SEARX_TEMPLATE $PI_SEARX_RUN" ]; then
      say "the running SearXNG (pid $pid) predates the current configuration; restart it: pi-searx-down && pi-searx-up"
    fi
  elif [ "$PI_SEARX_REUSE" != 1 ]; then
    say "refusing the server that answers on $url: pi-searx-up did not start it (programs.pi.search.local.reuseExisting is false)"
    exit 1
  elif [ ! -e "$state/foreign" ]; then
    # Once per state, not at every pi start while the same foreign instance serves.
    say "reusing the SearXNG that already answers on $url (not started by pi-searx-up; pi-searx-down leaves it alone)"
    : >"$state/foreign"
  fi
  exit 0
fi
rm -f "$state/foreign"

if ! ours "$pid"; then
  rm -f "$state/pid"
  # The per-user secret: generated once, never in the store, never on a command line.
  if [ ! -s "$state/secret" ]; then
    (umask 077 && od -A n -t x1 -N 32 /dev/urandom | tr -d ' \n' >"$state/secret.tmp")
    mv -f "$state/secret.tmp" "$state/secret"
  fi
  chmod 600 "$state/secret"
  secret=$(<"$state/secret")
  if [[ ! $secret =~ ^[0-9a-f]+$ ]]; then
    say "$state/secret is not a hex string; delete it and run pi-searx-up again"
    exit 1
  fi
  template=$(<"$PI_SEARX_TEMPLATE")
  (umask 077 && printf '%s\n' "${template//@PI_SEARX_SECRET@/$secret}" >"$settings.tmp")
  mv -f "$settings.tmp" "$settings"
  printf '%s %s\n' "$PI_SEARX_TEMPLATE" "$PI_SEARX_RUN" >"$state/source"

  # SearXNG lets SEARXNG_* variables override its settings: none from the caller's
  # environment, and the bind and the port pinned to the module's.
  unset "${!SEARXNG_@}"
  # Its own session: a closed terminal or a Ctrl-C in pi does not stop it. A background job
  # of a non-interactive shell leads no process group, so setsid does not fork and $! is
  # SearXNG itself. Without the lock's descriptor, which would hold the lock as long as it runs.
  SEARXNG_SETTINGS_PATH="$settings" SEARXNG_BIND_ADDRESS=127.0.0.1 SEARXNG_PORT="$PI_SEARX_PORT" \
    setsid "$PI_SEARX_RUN" </dev/null >>"$log" 2>&1 9>&- &
  pid=$!
  echo "$pid" >"$state/pid"
  started=1
else
  started=0 # still coming up from an earlier call that gave up
fi

# What is left of the budget (the lock wait came out of it); at least one probe.
deadline=$((t0 + budget))
while :; do
  if answers; then
    if [ "$started" = 1 ]; then say "started SearXNG (pid $pid) on $url"; fi
    exit 0
  fi
  kill -0 "$pid" 2>/dev/null || break
  ((SECONDS < deadline)) || break
  sleep 0.2
done
if kill -0 "$pid" 2>/dev/null; then
  say "SearXNG (pid $pid) does not answer on $url within $budget s; it may still be starting; see $log"
else
  rm -f "$state/pid"
  say "SearXNG exited without answering on $url; see $log"
fi
exit 1
