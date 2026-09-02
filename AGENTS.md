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
- Before production reliance, at least one ordinary development recipient must be omitted from prod; shared recovery and production-authorized developers may be explicit on both.
- Use `--require-prod-exclusive` when policy also requires a production-only hardware or workload identity.
- Run `ores-sops-access-audit check` with `ores-sops verify`; do not bypass a failed access audit by copying every key into prod.
- The v0.3 contract is exactly dev/prod. Do not add stage or another `env/enc` path without a versioned helper, policy, and test rollout.

See [`docs/scope.md`](docs/scope.md), [`docs/consumer-boundary.md`](docs/consumer-boundary.md), [`docs/fleet-audit.md`](docs/fleet-audit.md), and [`docs/access-control.md`](docs/access-control.md).
