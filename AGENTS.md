# ores-sops

Canonical SOPS dotenv contract for ORESoftware and consuming orgs.

- Secrets at rest: this repository (`env/enc` ciphertext, `env/dec` runtime plaintext).
- Telemetry: github.com/ores-otel — a different layer; it *consumes* this contract.
- Auth: github.com/shared-auth.
- Sync: github.com/opto-sync.
- Packages: github.com/zed-pkg.
- Flags: github.com/ORESoftware/flags-2-env.
- Deploy: github.com/oresoftware/k8s-cluster (Kubernetes Secret YAML is out of this dotenv namespace).
- Internal runtimes: Rust, TypeScript, Dart. Never React/JSX or webviews.
- Resolve git conflicts semantically; never rebase, stash, or reset.
- Never print, commit, or fixture private keys, decrypted dotenv, or ciphertext values.
- Treat `.sops.yaml` recipient changes as access-control changes: public age recipients are committed, private identities never are.
- With stage configured, at least one ordinary development recipient must be omitted from both stage and prod, and at least one stage recipient must be omitted from prod; shared recovery and elevated recipients remain explicit.
- Use `--require-prod-exclusive` when policy also requires a production-only hardware or workload identity.
- Run `ores-sops-access-audit check --require-ciphertext` with `ores-sops verify` so desired policy and actual ciphertext metadata must agree.
- Do not bypass a failed access audit by copying every key into prod or by using `--policy-only` after ciphertext exists.
- The v0.4 contract is exact dev/prod plus one optional exact stage environment; reject every other `env/enc` path.

See [`docs/scope.md`](docs/scope.md), [`docs/consumer-boundary.md`](docs/consumer-boundary.md), [`docs/fleet-audit.md`](docs/fleet-audit.md), and [`docs/access-control.md`](docs/access-control.md).
