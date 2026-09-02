# Consumer boundary for `env/enc` and `env/dec`

This document is normative for repositories that wrap `ores-sops` with Nix,
Just, Docker, or direct SOPS process execution.

## Threat model

`env/dec` is ignored local plaintext. A repository wrapper must not run
`mkdir`, `chmod`, `cp`, `rm`, `sops`, or a provider process against a managed
environment path until it has rejected repository-controlled path redirection.

This sequence is unsafe:

```just
use name:
    @mkdir -p env/dec
    @chmod 700 env/dec
    @ores-sops use {{ name }}
```

The helper cannot undo a chmod or plaintext write that the caller performed
through a pre-existing symlink before delegation.

## Canonical environments

The v0.4 contract recognizes only:

```text
dev
stage   # only when the exact stage rule is configured
prod
```

Wrappers must reject aliases such as `staging`, `qa`, arbitrary file paths, and
wildcard selections. Existing repositories without stage continue to expose
only dev/prod.

## Mandatory caller order

Every wrapper entry point that reads, creates, decrypts, edits, executes, or
removes environment material must first run one fail-closed tree guard. The
guard must:

1. Resolve the Git worktree root.
2. Reject symlink or non-directory forms of `env`, `env/enc`, and `env/dec`.
3. Reject symlink or non-regular forms of canonical ciphertext, plaintext, and
   stamp files.
4. Reject symlink or non-regular forms of policy files used by the workflow.
5. Permit root `.env` only as an exact relative symlink to
   `env/dec/dev.env`, configured `env/dec/stage.env`, or `env/dec/prod.env`.
6. Reject stage material or a stage `.env` target when the exact stage creation
   rule is absent.
7. Check the tree before creation, create directories under `umask 077`, check
   the tree again, and enforce `env/dec` mode `0700`.
8. Prove with `git check-ignore --no-index` that all `env/dec` plaintext is
   ignored.

After that boundary succeeds, delegate lifecycle operations to `ores-sops`. A
repository may use `ores-sops ensure-dec` when no stronger local file-policy
guard is needed, but it must never pre-touch `env/dec` before invoking the
helper.

Direct `sops exec-env` recipes must run behind the same guard and resolve only
`dev`, configured `stage`, or `prod`. They must construct the exact canonical
path internally rather than accepting a user-supplied path.

## Decryption authorization

The path guard protects the filesystem boundary; it does not grant decryption.
SOPS recipient metadata remains the cryptographic boundary:

- dev-only identities must fail on stage and prod;
- stage identities must be omitted from prod unless deliberately privileged;
- production and recovery identities may span lower environments only by
  explicit policy;
- private identities must not be shared between CI trust zones merely because
  wrappers accept the same environment name.

`ores-sops-access-audit` verifies the public recipient matrix and detects
`.sops.yaml` versus current ciphertext metadata drift.

## Required Docker build-context exclusions

A consumer Docker context must exclude plaintext, ciphertext, and private-key
material. Copy the canonical fragment from
[`templates/consumer.dockerignore`](../templates/consumer.dockerignore) into the
repository `.dockerignore` and enforce the exact lines in CI.

Ciphertext is excluded too. Encryption protects values at rest, but copying
ciphertext into local or remote build contexts unnecessarily distributes
secret-bearing artifacts through caches, provenance systems, and intermediate
layers. Containers should receive runtime values through a protected secret
store or process-scoped SOPS execution, never during `docker build`.

## CI contract

Keyless pull-request CI must prove at least:

- root, nested, suffixed, and `env/dec` plaintext paths are ignored;
- only exact dev/prod and, when configured, exact stage ciphertext paths are
  trackable;
- stage ciphertext cannot exist without the exact stage rule;
- tracked managed and policy paths are not symlinks;
- obvious plaintext assignments and private-key markers are absent;
- exact dev/prod rules and at most one exact stage rule are present;
- a stage-enabled access audit requires a true dev-only recipient;
- `--require-stage-exclusive` passes when stage access must be narrower than
  production access;
- desired recipients match actual public recipient metadata in every configured
  ciphertext;
- every environment-touching Just recipe invokes the tree guard;
- direct `mkdir -p env/dec` and `chmod 700 env/dec` bypasses are absent;
- required Docker exclusions remain present.

Protected decryptability checks may run only on trusted runners with authorized
identities. They must exercise positive and negative authorization cases without
printing values or uploading decrypted artifacts.

## Reference consumers

The first audited consumers using this boundary include:

- `shared-auth/shared-auth-server.rs`
- `ORESoftware/push-notification-server.rs`
- `benefactor-cc/backend.rs`

These repositories keep production Kubernetes secret ownership outside
application Git and use encrypted profiles only for reviewed developer/operator
workflows.
