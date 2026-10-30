# Citations never dangle.
# (1) Every `docs/<path>.md` named in a tracked text file exists in the source.
# (2) No tracked `.nix`, `.sh`, `.md` or `.yml` file cites a decision, task or
#     review id (a letter prefix and a number). Such ids belong to other
#     repositories' histories and would leak them. The register ids `AD<n>` of
#     docs/architecture.md are this repository's own and are not matched. A shell
#     variable such as `T2=` or `$T2` is not an id.
{
  pkgs,
  self,
}:
pkgs.runCommand "doc-refs" {nativeBuildInputs = [pkgs.gnugrep pkgs.coreutils];} ''
  cd ${self}
  fail=0
  while IFS=: read -r f t; do
    [ -e "$t" ] || { echo "doc-refs: $f cites $t, which does not exist"; fail=1; }
  done < <(grep -rIoE --exclude-dir=.git 'docs/[A-Za-z0-9._/-]+\.md' . | sort -u)
  while IFS=: read -r f id; do
    echo "doc-refs: $f cites the id $id; decision, task and review ids stay out of the repository"; fail=1
  done < <(grep -rIoP --exclude-dir=.git --include='*.nix' --include='*.sh' --include='*.md' --include='*.yml' \
    '(?<![$\w])(RF|R|S|T|D|F|K|A|M|G|P|Q|N|H|V|C|E|W|L|B)\d+(\.\d+)?[a-z]?\b(?![=/])' . | sort -u)
  [ "$fail" = 0 ] || exit 1
  touch $out
''
