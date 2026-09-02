# Just and repository build boundary

The root `justfile` is a convenience surface, not a second secret-management
implementation. It exposes fixed `dev` and `prod` recipes and delegates every
secret-adjacent operation to the packaged `ores-sops` command. It must not call
`sops` directly, create or chmod `env/dec`, parse dotenv, choose recipients, or
introduce a separate environment/profile convention.

The repository also treats Nix `result` and `result-*` links as local build
outputs. They are ignored and must never be tracked: a committed result link is
machine-specific, can point at a closure absent on every other host, and can be
mistaken for reviewable source or release evidence.

`scripts/check-repository-boundary.sh` enforces both rules without decrypting or
reading ciphertext values. Its adversarial test verifies that the guard rejects:

- tracked `result` / `result-*` output;
- direct `sops` recipes;
- direct `env/dec` creation or permission changes;
- arbitrary unreviewed recipe commands; and
- symlinked or non-regular Justfiles.

Run the focused boundary locally with:

```sh
bash scripts/check-repository-boundary.sh
bash tests/test-repository-boundary.sh
nix develop --command just --list
```

Run the complete platform contract with `just check` or `nix flake check -L`.
