# Consumer boundary for `env/enc` and `env/dec`

This document is normative for repositories that wrap `ores-sops` with Nix, Just, Docker, or direct SOPS process execution.

## Threat model

`env/dec` is ignored local plaintext. A repository wrapper must not run `mkdir`, `chmod`, `cp`, `rm`, `sops`, or a provider process against a managed environment path until it has rejected repository-controlled path redirection.

In particular, this sequence is unsafe:

```just
use name:
    @mkdir -p env/dec
    @chmod 700 env/dec
    @ores-sops use {{ name }}
```

The helper cannot undo a `chmod` or plaintext write that the caller performed through a pre-existing symlink before delegation.

## Mandatory caller order

Every wrapper entry point that reads, creates, decrypts, edits, executes, or removes environment material must first run one fail-closed tree guard. The guard must:

1. Resolve the Git worktree root.
2. Reject symlink or non-directory forms of `env`, `env/enc`, and `env/dec`.
3. Reject symlink or non-regular forms of the approved ciphertext, plaintext, and stamp files.
4. Reject symlink or non-regular forms of the policy files used by the workflow.
5. Permit root `.env` only as the exact relative symlink `env/dec/dev.env` or `env/dec/prod.env`.
6. Check the tree before creation, create directories under `umask 077`, check the tree again, and enforce `env/dec` mode `0700`.
7. Prove with `git check-ignore --no-index` that `env/dec` plaintext is ignored.

After that boundary succeeds, delegate lifecycle operations to `ores-sops`. A repository may use `ores-sops ensure-dec` when no stronger local file-policy guard is needed, but it must never pre-touch `env/dec` before invoking the helper.

Direct `sops exec-env` recipes must run behind the same guard and must resolve only one of the two fixed profiles, `dev` or `prod`. They must not accept an arbitrary path.

## Required Docker build-context exclusions

A consumer Docker context must exclude plaintext, ciphertext, and private-key material. Copy the canonical fragment from [`templates/consumer.dockerignore`](../templates/consumer.dockerignore) into the repository `.dockerignore` and enforce the exact lines in CI.

Ciphertext is intentionally excluded too. Encryption protects values at rest, but copying ciphertext into local or remote build contexts unnecessarily distributes secret-bearing artifacts through build caches, provenance systems, and intermediate layers. Containers should receive runtime values through the protected secret store or process-scoped SOPS execution, never during `docker build`.

## CI contract

Keyless pull-request CI must prove at least:

- root, nested, suffixed, and `env/dec` plaintext paths are ignored;
- only `env/enc/dev.env.enc` and `env/enc/prod.env.enc` are trackable;
- tracked managed and policy paths are not symlinks;
- obvious plaintext assignments and private-key markers are absent;
- exact dev/prod SOPS creation rules are present;
- production recipient separation passes the repository release policy;
- every environment-touching Just recipe invokes the tree guard;
- direct `mkdir -p env/dec` and `chmod 700 env/dec` bypasses are absent;
- required Docker exclusions remain present.

Protected decryptability checks may run only on trusted runners with authorized identities. They must not print values or upload decrypted artifacts.

## Reference consumers

The first audited consumers using this boundary are:

- `shared-auth/shared-auth-server.rs`
- `ORESoftware/push-notification-server.rs`
- `benefactor-cc/backend.rs`

These repositories keep production Kubernetes secret ownership outside application Git and use encrypted profiles only for reviewed developer/operator workflows.
