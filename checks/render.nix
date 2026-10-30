# The render checks: the committed rendered paths against the render fixture's output
# (`render.tree`, built by ../render/default.nix, which also refuses a store path in a
# rendered file). `diff -ru` names a differing, a missing and an extra file alike.
{
  pkgs,
  lib,
  self,
  render,
}: let
  mk = name: paths:
    pkgs.runCommand name {} ''
      for p in ${lib.escapeShellArgs paths}; do
        diff -ru ${render.tree}/$p ${self}/$p || {
          echo "${name}: $p differs from the Nix output; run nix run .#render" >&2
          exit 1
        }
      done
      touch $out
    '';
in {
  render-seed = mk "render-seed" ["settings"];
  # Also the dependency revisions: they are rendered from flake.lock, so a revision that
  # differs from the lock differs from the Nix output.
  render-package = mk "render-package" ["package.json"];
}
