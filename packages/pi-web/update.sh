#!/usr/bin/env bash
#
# Regenerate package-lock.json for a new @jmfederico/pi-web release.
#
#   1. edit the version in package.json
#   2. run this script (needs network)
#   3. run the printed `nix build`, paste the reported hash into default.nix
#
# Why this is not just `npm install`: npm writes nested `"peer": true` entries
# WITHOUT an `integrity` field, and nixpkgs' prefetch-npm-deps panics on them
# with "non-git dependencies should have associated integrity". Every such
# entry is a duplicate of a package that is fetched anyway, so the integrity is
# recovered — from the hoisted twin when there is one, from the registry when
# there is not. Nothing is invented: the integrity written is the registry's
# own, and the FOD hash would change if it were wrong.

set -euo pipefail

cd "$(dirname "$0")"

for tool in npm jq curl; do
	command -v "$tool" >/dev/null || {
		echo "update.sh: $tool is required" >&2
		exit 1
	}
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cp package.json "$work/"
(
	cd "$work"
	# A real install, not --package-lock-only: the latter resolves without
	# downloading and leaves even more entries without integrity.
	npm install --no-audit --no-fund >/dev/null
)

# Pass 1: copy integrity from another entry resolving to the same tarball.
jq '
  (.packages | to_entries
   | map(select(.value.resolved and .value.integrity)
         | {key: .value.resolved, value: .value.integrity})
   | from_entries) as $byUrl
  | .packages |= with_entries(
      if (.value.resolved and (.value.integrity | not) and $byUrl[.value.resolved])
      then .value.integrity = $byUrl[.value.resolved]
      else . end)
' "$work/package-lock.json" >"$work/pass1.json"

# Pass 2: whatever is left has no twin; ask the registry.
mapfile -t missing < <(
	jq -r '.packages | to_entries[]
           | select(.key != "" and .value.resolved and (.value.integrity | not))
           | "\(.key)\t\(.value.resolved)"' "$work/pass1.json"
)

cp "$work/pass1.json" "$work/final.json"
for row in "${missing[@]}"; do
	key=${row%%$'\t'*}
	url=${row#*$'\t'}
	name=$(printf '%s' "$key" | sed 's|.*node_modules/||')
	ver=$(jq -r --arg k "$key" '.packages[$k].version' "$work/final.json")

	integrity=$(curl -sSL --max-time 30 "https://registry.npmjs.org/$name/$ver" | jq -r '.dist.integrity')
	if [ -z "$integrity" ] || [ "$integrity" = null ]; then
		echo "update.sh: no integrity for $name@$ver ($url)" >&2
		exit 1
	fi

	jq --arg k "$key" --arg i "$integrity" \
		'.packages[$k].integrity = $i' "$work/final.json" >"$work/t.json"
	mv "$work/t.json" "$work/final.json"
done

remaining=$(jq '[.packages | to_entries[] | select(.key != "" and (.value.integrity | not))] | length' "$work/final.json")
if [ "$remaining" != 0 ]; then
	echo "update.sh: $remaining lock entries still lack integrity" >&2
	exit 1
fi

mv "$work/final.json" package-lock.json
echo "package-lock.json regenerated for $(jq -r '.packages["node_modules/@jmfederico/pi-web"].version' package-lock.json)"
echo
echo "Now set npmDepsHash in default.nix to lib.fakeHash, run:"
echo "  nix build .#pi-web --no-write-lock-file   (from the repository root)"
echo "and paste the hash it reports."
