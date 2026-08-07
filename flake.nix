{
  description = "ores-sops — repo-convention glue around sops (env/enc ciphertext, .env symlink, merge-aware refresh)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      overlay = final: prev: {
        ores-sops = final.writeShellApplication {
          name = "ores-sops";
          # Pinned into the closure so behaviour is identical everywhere and
          # nothing has to be installed on the host. git hooks in particular run
          # with a minimal PATH.
          runtimeInputs = with final; [
            sops
            age
            git
            coreutils
            gnugrep
            gnused
            diffutils
          ];
          # SC2064: cleanup traps intentionally capture the generated temp path
          # while it is in scope, so `set -u` cannot lose it on function return.
          # SC2094: verify_ciphertext_file reads a ciphertext while a diagnostic
          # command-substitution shell-escapes the *path string*; ShellCheck sees
          # the same variable name and conservatively reports possible same-file
          # read/write even though log_path only calls printf. Adversarial Bats
          # coverage exercises this verifier, so keep the exclusion explicit and
          # narrowly documented rather than disabling ShellCheck generally.
          excludeShellChecks = [ "SC2064" "SC2094" ];
          text = builtins.readFile ./ores-sops;
        };
      };
    in
    {
      overlays.default = overlay;

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
      lib.shellHook = ''
        export SOPS_AGE_KEY_FILE="''${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

        if command -v ores-sops >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
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
        packages.ores-sops = pkgs.ores-sops;
        packages.default = pkgs.ores-sops;

        apps.default = { type = "app"; program = "${pkgs.ores-sops}/bin/ores-sops"; };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ ores-sops sops age git just shellcheck bats ];
        };

        # The container entrypoint is shipped as an example people copy, so it
        # gets the same shellcheck gate as the tool itself.
        checks.entrypoint-shellcheck = pkgs.runCommand "entrypoint-shellcheck"
          { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          shellcheck --shell=sh ${./examples/docker/entrypoint.sh}
          touch "$out"
        '';

        checks.tests = pkgs.runCommand "ores-sops-tests"
          {
            nativeBuildInputs = with pkgs; [ ores-sops sops age git bats coreutils ];
          } ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          cp -r ${./tests} ./tests
          bats ./tests
          touch "$out"
        '';

        formatter = pkgs.nixpkgs-fmt;
      });
}
