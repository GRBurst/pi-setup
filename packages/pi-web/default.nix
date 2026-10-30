{
  lib,
  buildNpmPackage,
  nodejs,
  python3,
  makeWrapper,
}: let
  # The published package, not this shim. Read from the lockfile so the version
  # cannot drift from what is actually pinned.
  lock = builtins.fromJSON (builtins.readFile ./package-lock.json);
  version = lock.packages."node_modules/@jmfederico/pi-web".version;

  moduleRoot = "lib/node_modules/@jmfederico/pi-web";

  bins = {
    pi-web = "dist/cli.js";
    pi-web-server = "dist/server/index.js";
    pi-web-sessiond = "dist/server/sessiond.js";
  };
in
  buildNpmPackage {
    pname = "pi-web";
    inherit version;

    # PI WEB publishes a prebuilt `dist/` but no lockfile, and pi's own package
    # manager cannot install it: `pi install` shells out to `npm install
    # --legacy-peer-deps`, which skips the three non-optional
    # `@earendil-works/*` peer dependencies the standalone servers import at
    # startup. So the source here is a one-dependency shim whose committed
    # lockfile pins the whole closure, peers included.
    #
    # Only the two files the build reads, so editing this expression or
    # update.sh does not invalidate the dependency fetch.
    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./package.json
        ./package-lock.json
      ];
    };

    npmDepsHash = "sha256-HagiEa64lyb3mkZvdvHACQyr9LzZ7k9ZMedpZX1J1bY=";

    # Fetcher v1 populates a cacache that `npm ci` then rejects with ENOTCACHED
    # for the nested peer entries. v2 resolves them.
    npmDepsFetcherVersion = 2;

    # `dist/` is prebuilt in the published tarball; there is nothing to compile
    # except node-pty, which npm's install script handles.
    dontNpmBuild = true;

    # node-pty publishes no release assets, so its install script always falls
    # through to `node-gyp rebuild`. python3 is what makes that possible;
    # buildNpmPackage points node-gyp at this nodejs' headers, so nothing is
    # downloaded.
    nativeBuildInputs = [python3 makeWrapper];

    installPhase = ''
      runHook preInstall

      mkdir -p $out/lib
      cp -r node_modules $out/lib/node_modules

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: ''
          makeWrapper ${nodejs}/bin/node $out/bin/${name} \
            --add-flags $out/${moduleRoot}/${entry}
        '')
        bins)}

      runHook postInstall
    '';

    # A packaging error here is silent until someone opens a terminal in the
    # browser, so it is checked at build time instead.
    doInstallCheck = true;
    installCheckPhase = ''
      test -f $out/lib/node_modules/node-pty/build/Release/pty.node \
        || { echo "node-pty native module missing: browser terminals would not work" >&2; exit 1; }
      for p in pi-agent-core pi-ai pi-coding-agent; do
        test -d $out/lib/node_modules/@earendil-works/$p \
          || { echo "peer dependency @earendil-works/$p missing: the servers would not start" >&2; exit 1; }
      done
    '';

    passthru = {
      inherit moduleRoot;
      updateScript = ./update.sh;
    };

    meta = {
      description = "Web UI for the Pi coding agent";
      homepage = "https://pi-web.dev/";
      license = lib.licenses.mit;
      mainProgram = "pi-web";
      platforms = lib.platforms.linux;
    };
  }
