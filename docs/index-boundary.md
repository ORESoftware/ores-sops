# Exact-index environment boundary

`bash scripts/check-env-index.sh` validates one snapshot of the Git index. It uses `git write-tree`, NUL-delimited tree entries, immutable blob IDs, and a binary-aware private-key marker scan. It never decrypts or prints matched content.

This closes a staged/working-tree mismatch: a developer can stage unsafe bytes, replace the worktree with valid ciphertext without staging it, and otherwise pass a worktree-only check. The candidate commit must be the object being checked.

The contract remains exactly `env/enc/dev.env.enc` and `env/enc/prod.env.enc`. Ciphertext must be a regular non-executable Git blob. Nothing under `env/dec` may be tracked, including `.gitkeep` and `.env.example`. Public recipient documentation belongs outside `env/enc`. Unknown ciphertext paths, malformed/duplicate dotenv assignments, unexpected SOPS metadata assignments, symlinks, unresolved index stages, and staged private-key markers fail without printing values.

## Adoption

Run the index guard from the existing repository policy and from CI. It can be explicitly chained from an operator-reviewed pre-commit hook:

```sh
bash scripts/check-env-index.sh
```

This addition does not silently overwrite custom hooks or change the installed `ores-sops` package. Until consumers explicitly chain the guard, the older packaged pre-commit implementation retains its earlier behavior. The new repository workflow runs the guard for every pull request without a path filter.

## Evidence and limitations

`bash tests/test-env-boundary.sh` uses synthetic fixtures and requires no SOPS identity. Consumer copies additionally exercise `prepare-env-tree.sh`; `--with-just` requires a real Just executable and checks argument handling while SOPS/helper calls are stubbed.

`nix develop --no-update-lock-file -c bash tests/test-env-index-sops.sh` separately checks real SOPS serialization and local round trips with identities generated exclusively for the test. No identity, plaintext, or test ciphertext is uploaded or committed.

Structural validation is not authentication of the SOPS MAC, recipient-custody evidence, production readiness, credential rotation, historical Git cleanup, or a universal secret detector. Protected decryptability and application canaries remain separate gates. A process can stage additional changes after a local check; CI validates its own checked-out candidate. This guard does not scan submodule contents.

Related program: DEN-2636. The application dotenv namespace remains separate from Kubernetes KSOPS Secret YAML.
