# Security audit — 2026-08-07

Scope: `ORESoftware/ores-sops` after the exact `dev|prod` SOPS dotenv contract landed.

## Threat model

The helper routinely processes decrypted credentials on developer machines and may run automatically from Git hooks/dev shells. Treat repository-controlled paths and Git metadata as untrusted until validated. A malicious or accidentally malformed checkout must not be able to redirect plaintext outside the repository, make the helper overwrite unrelated files, bypass commit checks with unusual Git filenames, or cause CI to execute mutable third-party action tags.

## Findings hardened in this pass

### Managed-path symlink escape

`env`, `env/enc`, `env/dec`, approved ciphertext/plaintext files, and scaffold policy files are now rejected when they are symlinks in places where following them could redirect reads or writes. This prevents a checkout from turning a decrypt, encrypt, lock, edit, or init operation into an operation against a path outside the repository.

### Decrypted temporary-file lifecycle

Decrypted temporary files and diff baselines are created with owner-only permissions and receive EXIT/HUP/INT/TERM cleanup. `lock` also removes stale managed temp patterns left by an unclean termination. `env/dec` is mode `0700`; completed dotenv plaintext is mode `0600`.

### Git filename and rename bypasses

Pre-commit and verify use NUL-delimited Git path enumeration. The pre-commit gate includes additions, copies, modifications, renames, type changes, unmerged paths, and other non-deletion changes. Newline-containing filenames and rename-to-`.env` cases therefore cannot bypass the path policy.

### Tracked symlink and ciphertext-content checks

Approved ciphertext and policy paths may not be tracked as symlinks. Keyless verification also rejects unexpected `env/enc/*`, broad/noncanonical `env/enc` SOPS creation rules, obvious plaintext assignments inside approved ciphertext files, and tracked private-key material without printing the matching secret line.

### Hook installation boundary

`ores-sops install-hooks` now refuses custom `core.hooksPath` by default, because repository Git config can point that path outside `.git`. Operators may opt in only after review with `ORES_SOPS_ALLOW_CUSTOM_HOOKS_PATH=1`. Symlinked hook files/directories are rejected, and the absolute helper path is shell-escaped before being embedded into generated hooks.

### Dotenv validation

Managed plaintext is checked for malformed non-comment lines and duplicate variable names before it is encrypted or installed after decrypt. This prevents ambiguous duplicate-key behavior from becoming environment-dependent application state.

### CI supply-chain hardening

Third-party GitHub Actions are pinned to immutable commit SHAs. Checkout credentials are not persisted, job execution is time-bounded, and the keyless smoke gate includes common dotenv suffix variants plus owner-only decrypted-directory permissions.

## Residual / explicit boundaries

- `SIGKILL` cannot be trapped. A stale managed temp file after a hard kill is removed by `ores-sops lock`; disk-encryption and host access controls remain relevant.
- The bootstrap `init` path can initially use one local public age recipient for dev and prod. Production adoption still requires the separate recipient/KMS policy and recovery work tracked in Linear DEN-2641.
- This helper governs application dotenv ciphertext only. SOPS/KSOPS-encrypted Kubernetes Secret YAML is a separate GitOps artifact class and does not authorize additional `env/enc/*.env.enc` paths.
- Secrets already exposed to an identity are not revoked merely by removing the recipient. Offboarding/compromise requires `sops updatekeys`, data-key rotation where appropriate, and application credential rotation.

## Validation

The PR containing this audit must pass the keyless policy job and the full `nix flake check -L` job, including SOPS/age-backed Bats regression tests and ShellCheck, before merge.
