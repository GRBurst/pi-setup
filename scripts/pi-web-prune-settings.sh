# shellcheck shell=bash
#
# pi-web's sessiond auto-registers its own bundled `relays` pi-package by
# appending that path to the pi agent's settings.json. The path points into the
# pi-web package, so with a store-based install it goes stale on every version
# bump and the list grows without bound.
#
# A dangling entry is harmless -- verified: sessiond starts clean and logs
# nothing about it -- but they accumulate, so the ones whose target no longer
# exists are dropped before sessiond starts.
#
# Scope is deliberately narrow. pi and nono both write this file, so only
# string entries containing /nix/store whose target is gone are removed.
# Everything else -- objects, `npm:` specs, live paths -- is preserved, in
# order, because pi loads packages in list order.

settings="${PI_WEB_SETTINGS:?}"
[ -f "$settings" ] || exit 0

agentDir=$(dirname "$settings")

# Collect what to DROP rather than what to keep, so surviving entries keep
# their original positions.
drop='[]'
while IFS= read -r entry; do
	case "$entry" in
	*"/nix/store/"*)
		# The path sessiond records is relative to the agent dir.
		if [ ! -e "$agentDir/$entry" ]; then
			drop=$(printf '%s' "$drop" | jq --arg e "$entry" '. + [$e]')
		fi
		;;
	esac
done < <(jq -r '.packages[]? | select(type == "string")' "$settings")

[ "$drop" = '[]' ] && exit 0

# `. as $e` is load-bearing: inside `$drop | index(.)` the dot would be rebound
# to $drop, `index` would find the array within itself, and EVERY string entry
# would be dropped -- including pi's own packages. That regression is what
# checks/agent-web-prune exists for.
tmp=$(mktemp)
jq --argjson drop "$drop" \
	'.packages = ((.packages // [])
     | map(select(. as $e
         | ($e | type) != "string" or ($drop | index($e)) == null)))' \
	"$settings" >"$tmp" && mv "$tmp" "$settings"
