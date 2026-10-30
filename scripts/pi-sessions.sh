# shellcheck shell=bash
#
# List pi sessions, newest first, so one started in the browser can be resumed
# in the terminal with `pi --session <id>` (and the other way round). Both
# front ends share PI_CODING_AGENT_DIR; this is the view over it.

n=20
dir="${PI_SESSIONS_DIR:?}"

while [ $# -gt 0 ]; do
	case "$1" in
	-n)
		n="${2:?-n needs a count}"
		shift 2
		;;
	-d)
		dir="${2:?-d needs a directory}"
		shift 2
		;;
	-h | --help)
		cat >&2 <<-EOF
			usage: pi-sessions [-n COUNT] [-d SESSION_DIR]

			Columns: session id, last activity, working directory, first prompt.
			Resume with:  pi --session <id>
		EOF
		exit 0
		;;
	*)
		echo "pi-sessions: unknown argument: $1" >&2
		exit 2
		;;
	esac
done

if [ ! -d "$dir" ]; then
	echo "pi-sessions: no session directory at $dir" >&2
	exit 1
fi

# Process substitution, not a pipe into the loop: `head -n "$n"` closes the
# pipe early, and under `set -o pipefail` the resulting SIGPIPE on `sort` would
# fail the whole command after printing nothing.
mapfile -t entries < <(
	find "$dir" -mindepth 2 -maxdepth 2 -name '*.jsonl' -printf '%T@\t%p\n' 2>/dev/null |
		sort -rn | head -n "$n"
)

if [ "${#entries[@]}" -eq 0 ]; then
	echo "pi-sessions: no sessions under $dir" >&2
	exit 1
fi

for entry in "${entries[@]}"; do
	path="${entry#*$'\t'}"

	header=$(head -n 1 "$path" 2>/dev/null || true)
	id=$(printf '%s' "$header" | jq -r 'select(.type=="session") | .id' 2>/dev/null || true)

	# The session header records the cwd verbatim. The parent directory name
	# encodes it too, but lossily -- a directory whose own name contains '-'
	# is indistinguishable from a separator -- so it is only a fallback.
	cwd=$(printf '%s' "$header" | jq -r 'select(.type=="session") | .cwd' 2>/dev/null || true)

	# The file name embeds the same uuid, so a truncated or half-written
	# header still yields a resumable id.
	if [ -z "$id" ]; then
		base=$(basename "$path" .jsonl)
		id="${base#*_}"
	fi
	[ -n "$cwd" ] || cwd='?'

	# First user turn, as a title. Slurped from the first lines only: a long
	# session is megabytes, and `jq | head` would raise the same SIGPIPE.
	# The harness prepends skill definitions to the first user turn, so the raw
	# text starts with kilobytes of <skill> blocks. Everything up to the last
	# closing tag is dropped, leaving what the human actually typed.
	title=$(head -n 40 "$path" 2>/dev/null |
		jq -rs '
        map(select(.type == "message" and .message.role == "user"))
        | (.[0].message.content // [])
        | map(select(.type == "text") | .text)
        | (first // "")
        | sub("(?s)^.*</skill>\\s*"; "")
        | gsub("^\\s+|\\s+$"; "")
      ' 2>/dev/null || true)
	title=${title//$'\n'/ }
	title=${title:0:60}

	printf '%s  %s  %s  %s\n' \
		"$id" \
		"$(date -d "@$(stat -c %Y "$path")" '+%Y-%m-%d %H:%M')" \
		"$cwd" \
		"${title:--}"
done
