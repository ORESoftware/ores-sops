# ORESoftware SOPS fleet batches

The keyless fleet report scans public repositories before any broad mutation. Batch 1 remains the original five; batch 2 adds five more public candidates.

## Batch 1 candidates

- `devops-slack` — completed dummy-value real-consumer pilot; expected to be partial until a durable tracked key policy/ciphertext is intentionally provisioned.
- `slack-ores-integrations` — small active application with a tracked `.env.example`; useful next consumer candidate.
- `happy-wakey.rs` — documented root `.env` workflow and flags/env configuration; useful Rust consumer candidate.
- `ai-agent-coordinator.rs` — active coordinator repository with documented dotenv bootstrap; included for policy visibility, not automatic mutation.
- `flags-2-env` — adjacent ORESoftware environment tooling; included to detect whether the SOPS standard should interoperate without forcing secret storage into a repo that may not need it.

## Batch 2 candidates

- `r2g` — downstream-consumer test runner used across language SDKs.
- `r2g.example` — example consumer of r2g.
- `r2g.docker` — containerized r2g path.
- `ai-agent-bridge.rs` — public agent-bridge service candidate.
- `oresoftware.github.io` — public org site; included for policy visibility, not automatic secret storage.

`ORESoftware/project-registry` stays excluded: it is private and would require repository credentials, which would weaken this keyless survey lane.

## Explicit exclusions from automatic mutation

- transferred, archived, or superseded repositories;
- `push-notification-server.rs`, whose repository documentation says the active ownership path is being transferred to `fanwaave`;
- `k8s-cluster` and KSOPS-related work, because Kubernetes Secret YAML is a distinct GitOps artifact class and must not broaden the application-dotenv namespace;
- `sonus-auris/sonus-auris.infra` until its existing staging/release wildcard dotenv model is reconciled with the exact dev/prod application contract;
- repositories whose scan status is `conflicting`.

A `not-adopted` result is not automatically a defect: some repositories do not need secret-bearing dotenv files. A `partial` result likewise requires repository-context review before mutation.

## Report boundary

The workflow clones only public repositories and injects no decryption identity or service credential. The scanner emits only tracked-path counts and policy-state labels and never decrypts or reads dotenv/ciphertext values.

The initial report is a triage input. Adoption PRs should be created only for repositories where the runtime/parser/build/archive workflow genuinely benefits from the standard.

Tracking: DEN-2889 under DEN-2641.
