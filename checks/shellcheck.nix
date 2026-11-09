# shellcheck over an explicit file list. Every tracked `*.sh` (minus the leak
# fixtures) must be in exactly one of `checked` and `excluded`; a file in
# neither or in both fails the check by name. `checked` files run through
# `shellcheck -s bash`. Entries are shell globs relative to the repository root
# (`*` also crosses `/`); an entry that matches no file yet is allowed.
{
  pkgs,
  lib,
  self,
}: let
  checked = [
    "packages/pi-web/update.sh"
    "checks/leaks/scan.sh"
    "scripts/pi-searx.sh"
  ];
  # Frozen, covered another way:
  #  - scripts/pi-sessions.sh, scripts/pi-web-prune-settings.sh: kept byte-stable
  #    (their text is in the module's Nix path); covered as writeShellApplication
  #    and by checks/agent-web-prune;
  excluded = [
    "scripts/pi-sessions.sh"
    "scripts/pi-web-prune-settings.sh"
  ];
  lines = xs: lib.concatMapStrings (x: x + "\n") xs;
in
  pkgs.runCommand "shellcheck" {
    nativeBuildInputs = [pkgs.shellcheck pkgs.findutils pkgs.coreutils];
    checkedList = lines checked;
    excludedList = lines excluded;
  } ''
    cd ${self}
    fail=0
    matches() { # matches FILE LIST: FILE matches a glob of the newline-separated LIST
      local pat
      while IFS= read -r pat; do
        # shellcheck disable=SC2053
        [[ $1 == $pat ]] && return 0
      done <<<"$2"
      return 1
    }
    run=()
    while IFS= read -r f; do
      f=''${f#./}
      c=0; x=0
      matches "$f" "$checkedList" && c=1
      matches "$f" "$excludedList" && x=1
      if [ $((c + x)) = 0 ]; then
        echo "shellcheck: $f is in neither the checked nor the excluded list (checks/shellcheck.nix)"; fail=1
      elif [ $((c + x)) = 2 ]; then
        echo "shellcheck: $f is in both the checked and the excluded list (checks/shellcheck.nix)"; fail=1
      elif [ $c = 1 ]; then
        run+=("$f")
      fi
    done < <(find . -type f -name '*.sh' -not -path './checks/leaks/fixtures/*' | sort)
    if [ ''${#run[@]} -gt 0 ]; then
      shellcheck -s bash "''${run[@]}" || fail=1
    fi
    [ "$fail" = 0 ] || exit 1
    touch $out
  ''
