# The web-search extension's own tests over ./*.test.ts against the extension source
# in ../../extensions/web-search, offline, on both runtimes the extension meets:
# `node --test` (Node strips the types) and `bun test`. The pi package this flake
# builds against (nixpkgs' pi-coding-agent) runs on Node and ships no Bun; the
# standalone pi binaries are compiled with Bun, whose sockets, `lookup`, zlib and
# string handling differ from Node's. So the suite also runs on nixpkgs' Bun, the
# same release line those binaries embed. The tests inject the HTTP transport, the
# resolver and the search backends' fetch; the socket tests talk to loopback servers
# they start themselves.
{
  pkgs,
  lib,
}: let
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../extensions/web-search
      (lib.fileset.fileFilter (f: lib.hasSuffix ".test.ts" f.name) ./.)
    ];
  };
in
  pkgs.runCommand "web-search" {nativeBuildInputs = [pkgs.nodejs pkgs.bun];} ''
    cp -r ${src} src
    chmod -R u+w src
    cd src
    # ES modules without a package.json of the repository's own
    echo '{"type": "module"}' > package.json
    export HOME=$PWD
    node --test --test-reporter=spec checks/web-search/*.test.ts
    # bun's per-test default of 5 s is too tight for the 2 MiB conversion tests on a busy builder
    bun test --timeout 120000 ./checks/web-search/
    touch $out
  ''
