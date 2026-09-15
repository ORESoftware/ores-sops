# Minimal-plaintext `ores-sops exec`

Tracking: [#40](https://github.com/ORESoftware/ores-sops/issues/40)
Portable-config architecture: [ORESoftware/ores-docs#3](https://github.com/ORESoftware/ores-docs/issues/3)
Typed metadata contract: `contracts/portable-config/`

`ores-sops exec` is the first runtime-execution slice toward portable configuration. It deliberately solves **environment execution without plaintext materialization** before execution-profile ciphertext composition is admitted.

## Usage

```sh
ores-sops exec --env dev -- cargo test --all-targets
ores-sops exec --environment stage -- ./scripts/integration-test
```

The deployment environment remains exactly one of:

```text
dev | stage | prod
```

The environment is mandatory for `exec`; there is no implicit active/default environment. A bare `--` is mandatory before the child argv so ORESoftware CLI flags and downstream command flags cannot be confused.

## Security boundary

For an admitted POSIX invocation, the wrapper:

1. validates the exact deployment environment and bounded downstream argv;
2. verifies the repository-managed `env/enc` path and `.sops.yaml` are not symlink redirects;
3. requires the selected `env/enc/<environment>.env.enc` to be a regular non-symlink file;
4. requires an exact SOPS creation rule for that environment;
5. quotes each caller-supplied argv token for SOPS' Unix `/bin/sh -c` execution boundary;
6. invokes SOPS `exec-env` so decrypted values are injected into the child environment rather than written to `env/dec`;
7. returns the child's exit status to the caller.

This path does **not** create or update:

- `env/dec/<environment>.env`;
- the root `.env` symlink;
- `.env.sha256` stamps;
- GitHub step outputs, artifacts, or caches.

The command string passed to SOPS is derived only from the caller's already-admitted argv. Decrypted configuration values are not interpolated into that command string.

## Platform scope

This first slice is POSIX-only. Current SOPS `exec-env` executes through `/bin/sh -c` on Unix-like systems and `cmd.exe /C` on Windows. The quoting rules are different, so `ores-sops exec` fails closed on native Windows rather than claiming unsafe cross-platform equivalence.

A native Windows implementation requires a separately reviewed argv/quoting contract and adversarial fixtures.

## What this does not implement

This is **not the complete v0.5 profile-composition API**. In particular, it does not yet admit:

```text
env/enc/profiles/local.env.enc
env/enc/profiles/gha.env.enc
env/enc/profiles/gha-indie-worker.env.enc
env/enc/profiles/test.env.enc
```

and it does not accept `--profile`.

Those paths must remain rejected until `ores-sops` defines their exact SOPS recipient rules, collision/override semantics, and typed-manifest enforcement. The already-landed portable-config metadata contract remains the authority for that follow-up.

## Caller responsibilities

Do not put secret values on child argv. Operating systems, process monitors, CI diagnostics, or downstream tools may expose argv independently of SOPS. Pass secret application configuration through the encrypted environment contract instead.

The selected environment's SOPS recipients remain the authorization boundary. `ores-sops exec` does not broaden decryption rights, copy identities, or turn repository read access into plaintext access.

## Failure behavior

The wrapper fails closed on unsupported environments, missing exact policy, missing/unsafe ciphertext paths, unsafe managed symlinks, missing dependencies, malformed/oversized/control-character argv, absent child commands, or unsupported native-Windows execution.

Diagnostics contain fixed failure classes and safe environment/command metadata only. Downstream argv and decrypted values are not included in ORESoftware telemetry.
