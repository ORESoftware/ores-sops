{
  description = "ores-sops — repo-convention glue around sops (env/enc ciphertext, .env symlink, merge-aware refresh)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      flags2envRevision = "8892365548557e437d81a0d44d650fb9abff6c44";
      flags2envSrc = builtins.fetchGit {
        url = "https://github.com/flags-2-env/flags-2-env.git";
        rev = flags2envRevision;
      };

      overlay = final: prev: {
        flags2env = final.stdenv.mkDerivation {
          pname = "flags2env";
          version = "0.3.0-${builtins.substring 0 12 flags2envRevision}";
          src = flags2envSrc;

          nativeBuildInputs = with final; [
            makeWrapper
            nodejs_22
            node-gyp
            python3
          ];

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR"
            export npm_config_nodedir="${final.nodejs_22}"
            export npm_config_python="${final.python3}/bin/python3"
            (cd clients/nodejs && node-gyp rebuild)
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin" "$out/libexec/flags2env/build/Release"
            install -m 0755 clients/nodejs/cli.mjs "$out/libexec/flags2env/cli.mjs"
            install -m 0644 clients/nodejs/lib.mjs "$out/libexec/flags2env/lib.mjs"
            install -m 0644 clients/nodejs/build/Release/flags2env.node \
              "$out/libexec/flags2env/build/Release/flags2env.node"
            makeWrapper ${final.nodejs_22}/bin/node "$out/bin/flags2env" \
              --add-flags "$out/libexec/flags2env/cli.mjs"
            ln -s flags2env "$out/bin/f2e"
            runHook postInstall
          '';
        };

        ores-sops = final.stdenvNoCC.mkDerivation {
          pname = "ores-sops";
          version = "0.4.0";
          src = ./.;
          dontBuild = true;
          nativeBuildInputs = [ final.makeWrapper ];

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin" "$out/libexec/ores-sops/scripts"
            install -m 0755 ores-sops "$out/libexec/ores-sops/ores-sops"
            install -m 0644 .cli-flags.toml "$out/libexec/ores-sops/.cli-flags.toml"
            install -m 0755 scripts/ores-sops-core "$out/libexec/ores-sops/scripts/ores-sops-core"
            install -m 0755 scripts/ores-sops-telemetry "$out/libexec/ores-sops/scripts/ores-sops-telemetry"
            makeWrapper "$out/libexec/ores-sops/ores-sops" "$out/bin/ores-sops" \
              --prefix PATH : ${final.lib.makeBinPath (with final; [
                flags2env
                nodejs_22
                bash
                sops
                age
                git
                coreutils
                gnugrep
                gnused
                diffutils
              ])}
            runHook postInstall
          '';
        };

        ores-sops-fleet-audit = final.writeShellApplication {
          name = "ores-sops-fleet-audit";
          # Default scan is keyless path/policy metadata. --provider-inventory
          # additionally reads variable *names* from tracked env/enc blobs and
          # never emits ciphertext or plaintext values.
          runtimeInputs = with final; [
            git
            coreutils
            gnugrep
            gawk
          ];
          text = builtins.readFile ./scripts/fleet-audit.sh;
        };

        ores-sops-access-audit = final.writeShellApplication {
          name = "ores-sops-access-audit";
          # This audit reads only .sops.yaml and compares public age recipient
          # sets. It never opens ciphertext or private identity files.
          runtimeInputs = with final; [
            coreutils
            gnugrep
            gnused
          ];
          text = builtins.readFile ./scripts/access-audit.sh;
        };
      };
    in
    {
      overlays.default = overlay;

      # Nix-shell fallback when ores-sops is not yet on PATH. Canonical
      # creation is `ores-sops ensure-dec` (symlink-safe, fail-closed).
      # Consumers must not mkdir/chmod env/dec themselves; see
      # docs/consumer-boundary.md. Empty directories do not survive Git, so
      # every shell entry recreates the ignored plaintext boundary.
      # Refuse repo-controlled symlink redirection instead of following it.
      lib.prepareEnvDec = ''
        _ores_sops_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        if [ -L "$_ores_sops_root/env" ] || [ -L "$_ores_sops_root/env/dec" ]; then
          echo "env: refusing to prepare symlinked env/dec" >&2
        else
          mkdir -p "$_ores_sops_root/env/dec"
          chmod 700 "$_ores_sops_root/env/dec"
        fi
        unset _ores_sops_root
      '';

      # Drop this into any repo's devShell to get the hooks installed and the
      # active environment kept current:
      #
      #   devShells.default = pkgs.mkShell {
      #     packages = [ ores-sops.packages.${system}.default ];
      #     shellHook = ores-sops.lib.shellHook;
      #   };
      #
      # It deliberately does NOT pick an environment for you: auto-decrypting a
      # default would write live credentials to disk in a repo you only opened
      # to read. The first activation stays explicit; after that it self-updates.
      lib.shellHook = self.lib.prepareEnvDec + ''
        export SOPS_AGE_KEY_FILE="''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

        if command -v ores-sops >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
          # env/dec is runtime-only and cannot exist in a fresh clone.
          # Create it before every other Nix/SOPS integration path.
          ores-sops ensure-dec
          # .git/hooks is not shared by git, so every clone needs this once.
          ores-sops install-hooks --quiet || true
          ores-sops refresh || true
          if [ -L .env ]; then
            echo "env: .env -> $(readlink .env)"
          elif [ -d env/enc ]; then
            echo "env: none active — run 'just use <name>'"
          fi
        fi
      '';

      lib.forSystem = system:
        (import nixpkgs { inherit system; overlays = [ overlay ]; }).ores-sops;
    }
    // flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; overlays = [ overlay ]; };
      in {
        packages.flags2env = pkgs.flags2env;
        packages.ores-sops = pkgs.ores-sops;
        packages.ores-sops-fleet-audit = pkgs.ores-sops-fleet-audit;
        packages.ores-sops-access-audit = pkgs.ores-sops-access-audit;
        packages.default = pkgs.ores-sops;

        apps.default = { type = "app"; program = "${pkgs.ores-sops}/bin/ores-sops"; };
        apps.fleet-audit = {
          type = "app";
          program = "${pkgs.ores-sops-fleet-audit}/bin/ores-sops-fleet-audit";
        };
        apps.access-audit = {
          type = "app";
          program = "${pkgs.ores-sops-access-audit}/bin/ores-sops-access-audit";
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            flags2env
            ores-sops
            ores-sops-fleet-audit
            ores-sops-access-audit
            sops
            age
            git
            just
            shellcheck
            bats
          ];
        };

        # The container entrypoint is shipped as an example people copy, so it
        # gets the same shellcheck gate as the tool itself.
        checks.entrypoint-shellcheck = pkgs.runCommand "entrypoint-shellcheck"
          { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          shellcheck --shell=sh ${./examples/docker/entrypoint.sh}
          touch "$out"
        '';

        checks.helper-shellcheck = pkgs.runCommand "helper-shellcheck"
          { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          shellcheck --shell=bash ${./ores-sops}
          shellcheck --shell=bash ${./scripts/ores-sops-core}
          shellcheck --shell=bash ${./scripts/ores-sops-telemetry}
          shellcheck --shell=bash ${./scripts/fleet-audit.sh}
          shellcheck --shell=bash ${./scripts/access-audit.sh}
          shellcheck --shell=bash ${./tests/runtime-admission.sh}
          shellcheck --shell=bash ${./tests/flags2env-integration.sh}
          touch "$out"
        '';

        checks.flags2env-package = pkgs.runCommand "flags2env-package"
          { nativeBuildInputs = [ pkgs.flags2env ]; } ''
          mkdir work
          cd work
          cp ${./.cli-flags.toml} .cli-flags.toml
          flags2env audit ./.cli-flags.toml >/dev/null
          touch "$out"
        '';

        checks.packaged-runtime-admission = pkgs.runCommand "packaged-runtime-admission"
          { nativeBuildInputs = [ pkgs.ores-sops ]; } ''
          ores-sops --version >/dev/null
          touch "$out"
        '';

        checks.prepare-env-dec = pkgs.runCommand "prepare-env-dec"
          { nativeBuildInputs = [ pkgs.git pkgs.coreutils ]; } ''
          mkdir normal
          cd normal
          git init -q
          ${self.lib.prepareEnvDec}
          test -d env/dec
          test "$(stat -c '%a' env/dec 2>/dev/null || stat -f '%Lp' env/dec)" = 700
          cd ..

          mkdir redirected outside
          cd redirected
          git init -q
          ln -s ../outside env
          ${self.lib.prepareEnvDec}
          test ! -e ../outside/dec
          cd ..

          touch "$out"
        '';

        checks.tests = pkgs.runCommand "ores-sops-tests"
          {
            nativeBuildInputs = with pkgs; [
              ores-sops
              ores-sops-fleet-audit
              ores-sops-access-audit
              sops
              age
              git
              bats
              coreutils
            ];
          } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          cp -r ${./tests} ./tests
          cp -r ${./templates} ./templates
          cp -r ${./examples} ./examples
          bats ./tests
          touch "$out"
        '';

        formatter = pkgs.nixpkgs-fmt;
      });
}
