# ores-sops

Canonical SOPS dotenv contract for ORESoftware and consuming orgs.

- Secrets at rest: this repository (`env/enc` ciphertext, `env/dec` runtime plaintext).
- Telemetry: github.com/ores-otel — a different layer; it consumes this contract.
- Auth: github.com/shared-auth.
- Sync: github.com/opto-sync.
- Packages: github.com/zed-pkg.
- Flags: github.com/ORESoftware/flags-2-env.
- Deploy: github.com/oresoftware/k8s-cluster (Kubernetes Secret YAML is outside this dotenv namespace).
- Internal runtimes: Rust, TypeScript, Dart. Never React/JSX or webviews.
- Resolve Git conflicts semantically; never rebase, stash, or reset another agent's work.
- Never print, commit, or fixture private identities, decrypted dotenv, ciphertext values, or realistic credentials.
- Treat `.sops.yaml` recipient changes as access-control changes: public age recipients are committed; private identities never are.
- The v0.4 contract requires exact dev/prod rules and permits one optional exact stage rule. Never introduce `staging`, `qa`, wildcards, or arbitrary `env/enc` names.
- A three-environment policy must retain at least one true dev-only recipient omitted from both stage and prod. Use `--require-stage-exclusive` when stage must retain a recipient omitted from prod, and `--require-prod-exclusive` when production must have a production-only hardware/workload identity.
- Production-authorized people and offline recovery may appear on multiple files only by deliberate policy.
- Run `ores-sops verify` plus `ores-sops-access-audit check --require-stage --require-stage-exclusive --require-ciphertext` for stage-enabled repositories.
- Do not bypass a failed access audit by copying every recipient into higher environments or by using `--policy-only` after ciphertext exists.
- Recipient removals are incomplete until the affected ciphertext has been updated with `ores-sops sync-keys <environment>` or `sops updatekeys`; rotate data keys and application credentials when the incident requires it.

See [`docs/scope.md`](docs/scope.md), [`docs/consumer-boundary.md`](docs/consumer-boundary.md), [`docs/fleet-audit.md`](docs/fleet-audit.md), and [`docs/access-control.md`](docs/access-control.md).
