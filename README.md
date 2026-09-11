# ores-sops

`ores-sops` is the canonical ORESoftware repository convention around SOPS and
age for dotenv secrets stored in Git.

It is a secrets-at-rest and local-activation layer. It is not observability,
authentication, package management, or runtime secret distribution:

| Layer | Repository | Responsibility |
| --- | --- | --- |
| Secrets at rest in Git | `ORESoftware/ores-sops` | Exact dotenv ciphertext paths, recipient policy, local activation |
| Logs, traces, metrics | `ores-otel/*` | OpenTelemetry and application observability |
| Authentication | `shared-auth/*` | User and organization authentication |
| Package management | `zed-pkg/*` | Dependency and package distribution |

## v0.4 contract

Development and production are required. Stage is one optional, exact third
environment:

```text
env/enc/dev.env.enc
env/enc/stage.env.enc   # present only when the exact stage rule is configured
env/enc/prod.env.enc
```

Plaintext is local-only and never tracked:

```text
env/dec/dev.env
env/dec/stage.env
env/dec/prod.env

.env -> env/dec/dev.env
# or env/dec/stage.env
# or env/dec/prod.env
```

Arbitrary aliases such as `staging`, `qa`, `release`, and wildcard `env/enc`
rules are rejected. Existing v0.3 dev/prod repositories remain valid without a
stage rule or stage file.

The `env/dec/` directory is runtime-only. Every managed command creates it
through `ores-sops ensure-dec`, rejects symlink redirection, and applies mode
`0700`. Completed plaintext files use mode `0600` and are installed atomically.
The root `.env` is a relative managed symlink; an unmanaged `.env` is never
overwritten or deleted.

## Access is per ciphertext file

Every human or workload receives an individual age identity. Only the public
`age1...` recipient is committed. The private identity must remain on the local
device, hardware token, protected workload, KMS integration, or secret manager.

A repository reader can see encrypted blobs and public recipient metadata. That
does not grant decryption. A private identity can decrypt only a ciphertext that
lists its matching public recipient.

Recommended matrix:

| Identity class | dev | stage | prod |
| --- | ---: | ---: | ---: |
| ordinary developer | yes | no | no |
| release engineer | yes | yes | no |
| production-authorized engineer | yes | yes | yes |
| dev CI | yes | no | no |
| stage deploy workload | no | yes | no |
| prod deploy workload | no | no | yes |
| offline recovery | yes | yes | yes |

A strict three-environment policy therefore includes at least:

- one true development-only recipient, absent from stage and prod;
- one stage recipient absent from prod;
- optionally one true production-only recipient;
- one independently controlled recovery recipient on every environment.

See [`docs/access-control.md`](docs/access-control.md) for onboarding,
offboarding, key rotation, historical Git access, and stronger threshold policy.

## Canonical three-environment policy

Replace the placeholders with real public age recipients. Never commit an
`AGE-SECRET-KEY-...` identity.

```yaml
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1_DEV_DEVELOPER_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_DEV_CI_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT

  - path_regex: ^env/enc/stage\.env\.enc$
    age:
      - age1_RELEASE_ENGINEER_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_STAGE_DEPLOY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT

  - path_regex: ^env/enc/prod\.env\.enc$
    age:
      - age1_PROD_OPERATOR_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_PROD_DEPLOY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
```

SOPS uses one file data key per ciphertext and wraps that file key for only the
recipients on the matching rule. Editing `.sops.yaml` changes desired policy;
existing ciphertext keeps its current recipient metadata until `sops
updatekeys` or `ores-sops sync-keys` is run for that file.

## Required ignore policy

A stage-enabled repository uses:

```gitignore
*.env
*/*.env
*/**/*.env
.env.*
*.env.*
!.env.example

/env/dec/

/env/enc/*
!/env/enc/dev.env.enc
!/env/enc/stage.env.enc
!/env/enc/prod.env.enc
```

A legacy two-environment repository may omit the stage exception while stage is
not configured. The helper requires the stage exception as soon as the exact
stage rule is present.

## Initialization

Generate a local identity:

```sh
age-keygen -o ~/.config/sops/age/keys.txt
```

Legacy-compatible two-environment bootstrap:

```sh
ores-sops init
```

Recommended scoped three-environment bootstrap:

```sh
ores-sops init \
  --with-stage \
  --stage-recipient age1_STAGE_PUBLIC_RECIPIENT \
  --prod-recipient age1_PROD_PUBLIC_RECIPIENT \
  --recovery-recipient age1_RECOVERY_PUBLIC_RECIPIENT
```

When any scoped option is used, the local identity begins as development-only.
It is not added to stage or prod unless its public recipient is supplied there
explicitly.

Available initialization options are repeatable:

```text
--recipient K           common/legacy recipient on every configured environment
--dev-recipient K       dev only
--stage-recipient K     stage only; also enables stage
--prod-recipient K      prod only
--recovery-recipient K  every configured environment
```

The corresponding `ORES_SOPS_*_RECIPIENTS` variables accept comma- or
space-separated public recipients.

## Daily use

```sh
# Create or modify ignored plaintext, then encrypt it.
$EDITOR env/dec/dev.env
ores-sops encrypt dev

$EDITOR env/dec/stage.env
ores-sops encrypt stage

# Prefer direct ciphertext editing for routine secret changes.
ores-sops edit prod

# Activate exactly one environment locally.
ores-sops use stage
# .env -> env/dec/stage.env

# Remove all managed plaintext and temporary state.
ores-sops lock
```

Because `.env.enc` does not identify the dotenv store, every SOPS invocation uses
explicit `--input-type dotenv --output-type dotenv`. Encryption also uses a
filename override so the exact destination rule is selected deterministically.

## Recipient changes

After changing one environment's public recipient list, synchronize only that
ciphertext:

```sh
ores-sops sync-keys stage
```

Equivalent direct command:

```sh
sops updatekeys -y --input-type dotenv env/enc/stage.env.enc
```

The access audit detects desired-versus-actual recipient drift, so a safer
`.sops.yaml` change cannot be mistaken for completed revocation.

For compromise or offboarding that requires a fresh data key:

```sh
sops --rotate --in-place \
  --input-type dotenv \
  --output-type dotenv \
  env/enc/prod.env.enc
```

Rotate the application credentials themselves when a removed identity may have
learned them. Rekeying current ciphertext does not revoke knowledge of earlier
plaintext or make historical Git revisions undecryptable.

## Commands

```text
ores-sops init [--with-stage] [recipient options]
ores-sops use dev|stage|prod [--force]
ores-sops encrypt dev|stage|prod [--allow-empty]
ores-sops edit dev|stage|prod
ores-sops sync-keys dev|stage|prod
ores-sops diff dev|stage|prod
ores-sops status
ores-sops refresh
ores-sops verify
ores-sops precommit
ores-sops lock
ores-sops install-hooks
ores-sops ensure-dec
```

`diff` reports only key names and whether each key was added, removed, or
changed. Values are hashed internally and never printed.

## Access-policy gate

For a stage-enabled production repository:

```sh
ores-sops verify

ores-sops-access-audit check \
  --require-stage \
  --require-stage-exclusive \
  --require-ciphertext
```

Add `--require-prod-exclusive` when the policy requires a production-only
hardware or workload identity. Before ciphertext exists, the explicit bootstrap
mode is:

```sh
ores-sops-access-audit check \
  --require-stage \
  --require-stage-exclusive \
  --policy-only
```

The access audit never decrypts. It compares public age recipients in the exact
creation rules with public recipient metadata in the configured ciphertexts.
Normal output contains counts only; `show` is the explicit command that prints
public recipients.

## Verification and hooks

`ores-sops verify` checks, without a private key:

- exact dev/prod and optional exact stage rules;
- stage material cannot exist without the stage rule;
- canonical Git allowlisting and plaintext ignore behavior;
- no unexpected `env/enc/*` path or tracked plaintext dotenv;
- no policy, ciphertext, managed directory, or hook symlink escape;
- dotenv ciphertext structure and no obvious plaintext assignment;
- owner-only local modes and managed relative `.env` targets;
- no tracked age, PEM, or OpenSSH private-key material.

Trusted environments may additionally set `ORES_SOPS_VERIFY_DECRYPT=1`.

`ores-sops install-hooks` installs managed refresh hooks and a NUL-safe
pre-commit guard. Existing unmanaged hooks are preserved. A custom
`core.hooksPath` is rejected unless explicitly reviewed and opted in.

## Fleet audit

```sh
nix run .#fleet-audit -- ../repo-a ../repo-b
```

The keyless fleet audit accepts both valid legacy dev/prod repositories and the
exact optional stage extension. A tracked stage ciphertext without its exact
rule is conflicting. Provider inventory reports plus-joined environment names,
for example `dev+stage`, `stage+prod`, or `dev+stage+prod`, without printing
values. See [`docs/fleet-audit.md`](docs/fleet-audit.md).

## Containers and CI

Do not decrypt during `docker build`; image layers are persistent. Inject
secrets at runtime or use SOPS process execution. Fork-originated pull requests
must not receive any decryption identity. Protected deployment workflows should
use separate dev, stage, and prod workload identities.

CI, logs, artifacts, caches, screenshots, issues, pull requests, Linear, and
fixtures must never contain private identities, decrypted dotenv values,
service-account keys, or realistic credentials.

## Nix

```nix
{
  inputs.ores-sops.url = "github:ORESoftware/ores-sops";

  devShells.default = pkgs.mkShell {
    packages = [ ores-sops.packages.${system}.default ];
    shellHook = ores-sops.lib.shellHook;
  };
}
```

The flake pins SOPS, age, Git, and shell dependencies and exposes the helper,
access audit, and fleet audit. The shell hook creates the ignored runtime
directory, installs safe hooks, and refreshes an already selected environment;
it never chooses or auto-decrypts an environment on first entry.

## Migration from v0.3

Existing dev/prod repositories continue to pass unchanged. To opt into stage:

1. upgrade to `ores-sops` v0.4;
2. add one exact stage rule with stage-approved public recipients;
3. add `!/env/enc/stage.env.enc` after the broad `env/enc/*` ignore;
4. create `env/dec/stage.env` locally and run `ores-sops encrypt stage`;
5. run the strict three-environment access audit;
6. review `.sops.yaml`, stage ciphertext, and deployment workflow changes under
   protected ownership.

`ores-sops init --with-stage` can add the exact rule and allowlist to an existing
repository, but recipient policy still requires human/security review.

## Tests

```sh
nix develop --command bats tests/
nix flake check -L
```

The suite includes real generated age identities and proves the full negative
decrypt matrix: dev cannot decrypt stage/prod, stage cannot decrypt dev/prod,
prod cannot decrypt dev/stage, and recovery can decrypt all three. It also
covers atomic activation, failed-decrypt preservation, scoped initialization,
recipient drift and rekeying, stage-only mutation, legacy compatibility, fleet
classification, symlink resistance, cleanup, hooks, and non-secret output.

## Documentation

- [`docs/access-control.md`](docs/access-control.md) — recipient matrices and key lifecycle
- [`docs/consumer-boundary.md`](docs/consumer-boundary.md) — caller order, containers, and CI
- [`docs/runtime-directory.md`](docs/runtime-directory.md) — safe `env/dec` creation
- [`docs/fleet-audit.md`](docs/fleet-audit.md) — keyless fleet classification
- [`docs/initial-fleet-batch.md`](docs/initial-fleet-batch.md) — rollout batches
- [`docs/security-audit-2026-08-07.md`](docs/security-audit-2026-08-07.md) — initial security review
