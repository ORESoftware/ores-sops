# SOPS fleet security audit — 2026-09-12

This audit covers the canonical `ORESoftware/ores-sops` contract and a direct
sample of **100 repositories across 20 GitHub organizations** (five repositories
per organization). The audit is keyless: it inspects repository policy and file
layout only. It does not decrypt ciphertext, print secret values, or require a
private age identity.

## Scope

The sampled organizations and root `.sops.yaml` adoption counts were:

| Organization | Repositories checked | `.sops.yaml` present |
| --- | ---: | ---: |
| `ores-otel` | 5 | 2 |
| `ores-forms` | 5 | 0 |
| `ores-rate-limit` | 5 | 0 |
| `ores-redis-lru-cache` | 5 | 0 |
| `ores-chat` | 5 | 0 |
| `ores-legal` | 5 | 0 |
| `ores-dnd` | 5 | 0 |
| `shared-auth` | 5 | 5 |
| `fanwaave` | 5 | 3 |
| `zed-pkg` | 5 | 3 |
| `elenkos-systems` | 5 | 0 |
| `messaging-intel` | 5 | 2 |
| `ecma-d` | 5 | 4 |
| `fiducia-cloud` | 5 | 5 |
| `sonus-auris` | 5 | 2 |
| `gha-indie-worker` | 5 | 1 |
| `hhaus-org` | 5 | 0 |
| `flags-2-env` | 5 | 1 |
| `file-tunnel` | 5 | 2 |
| `opto-sync` | 5 | 3 |
| **Total** | **100** | **33** |

A missing `.sops.yaml` is not automatically a defect. Repositories that do not
own encrypted developer/operator profiles should remain non-adopted rather than
receive copied recipients or placeholder ciphertext. Empty repositories are
also reported separately by the inventory tooling and must not be treated as
policy failures.

## High-confidence findings

### 1. Central staged-index admission disagreed with the v0.4 contract

The public contract and runtime support optional `stage`, but
`scripts/check-env-index.sh` admitted only `dev.env.enc` and `prod.env.enc`.
That meant a valid staged `stage.env.enc` could be rejected even when the exact
stage creation rule was staged with it.

The same index gate allowed `.env.example` but rejected the documented safe
suffixes `.env.sample` and `.env.template`. It also accepted executable modes
for policy/example files.

This hardening branch fixes all three problems while deriving optional stage
admission from the **candidate Git tree**, never an unstaged working-tree
replacement of `.sops.yaml`.

### 2. Legacy wildcard rules exist in active consumers

Confirmed examples include:

- `ores-otel/ores.otel.log`
- `ores-otel/ores-lib-core`
- `zed-pkg/zed-cli`
- `file-tunnel/ftnl-backend-api.rs`
- `file-tunnel/ftnl-web-server.rs`

These policies contain a broad form such as
`^env/enc/.*\.env\.enc$` (or an equivalent unanchored rule). Broad rules are
not part of the canonical contract because they admit arbitrary profile names
and make recipient intent ambiguous. The canonical set is exact `dev`, exact
`prod`, and exact `stage` only when stage is deliberately configured.

The current `zed-cli` policy also names `staging`; the canonical environment
name is `stage`. Its tracked ciphertext currently contains only `dev.env.enc`
and `prod.env.enc`, so the noncanonical alias is policy drift rather than a
tracked compatibility requirement.

### 3. Single-group `key_groups` copies cannot pass the age-list access audit

Confirmed examples include legacy/copy-derived policies in `ores-otel`,
`fanwaave`, `zed-pkg`, `gha-indie-worker`, `flags-2-env`, and `file-tunnel`.

`ores-sops-access-audit` intentionally fails closed on `key_groups`: threshold
policy has different semantics and must receive a separate threshold-policy
review. Several sampled files use only one age key group and no threshold,
which provides no threshold security benefit but still prevents the ordinary
recipient-matrix audit from proving dev/prod separation.

Where the single key group is only an OR-list of age recipients, migration to
plain `age:` lists preserves the recipient set while restoring auditable
semantics. Do not perform that rewrite when a repository deliberately uses
multiple groups or a Shamir threshold.

### 4. File Tunnel has both wildcard scope and single-recipient custody

`file-tunnel/ftnl-backend-api.rs` and `file-tunnel/ftnl-web-server.rs` use a
wildcard env rule and one operator recipient. The policy comments state that
recipient custody is shared with the File Tunnel infrastructure repository.
This needs a repository-specific custody review before adding any second
recipient: **never copy a recovery key from another repository merely to make a
minimum-recipient check green**.

### 5. The central policy repository's `main` ref is not branch-protected

The GitHub branch metadata observed during this audit reported `protected:
false` for `ORESoftware/ores-sops` `main`. Because this repository defines the
fleet secret boundary, branch/ruleset enforcement should require PR review and
keyless security checks. GitHub App access used for this audit cannot safely
change organization administration/ruleset policy, so this remains an explicit
administrative follow-up rather than being silently bypassed.

## Positive controls

The sampled `shared-auth` policies use exact anchored dev/prod paths and plain
age recipient lists, with distinct protected production and development
recipient sets plus recovery custody. This is the preferred age-list policy
shape for repositories that do not deliberately require threshold key groups.

`opto-sync/opto-sync-clients` uses the same exact-rule policy family.

## Required fleet contract

For repositories that adopt the encrypted dotenv contract:

1. Track only `env/enc/dev.env.enc`, `env/enc/prod.env.enc`, and optional exact
   `env/enc/stage.env.enc`.
2. Ignore every `env/dec/**` plaintext path and the managed root `.env` link.
3. Reject symlink/non-regular forms of managed policy, ciphertext, plaintext,
   and stamp paths before any create/chmod/decrypt/edit operation.
4. Keep policy/example files mode `0644`; ciphertext is a non-executable regular
   blob.
5. Use exact SOPS creation rules. No wildcard fallback and no aliases such as
   `staging` or `qa`.
6. Prefer plain `age:` lists for OR-access. Use `key_groups` only with a
   deliberately reviewed threshold policy and separate validation.
7. Keep private identities out of Git, PR CI, logs, caches, artifacts and build
   contexts. Public `age1...` recipients are policy metadata, not private keys.
8. Exclude both plaintext and ciphertext from Docker build contexts; inject
   runtime values through a protected secret store or process-scoped SOPS
   execution.
9. Run keyless index/repository/access-policy checks on every PR. Decryptability
   witnesses run only on trusted protected hosts.
10. Never invent or copy recipients between repositories to satisfy a numeric
    policy gate. Recipient custody is a security decision.

## Remediation order

1. Merge the central index-gate regressions in this branch.
2. Normalize single-group legacy policies without changing recipient sets.
3. Remove broad wildcard rules only after proving tracked `env/enc` contains no
   noncanonical ciphertext that depends on them.
4. Resolve `staging` → `stage` only where no tracked compatibility artifact
   requires migration; otherwise perform an explicit re-encryption/rename plan.
5. Review File Tunnel recipient custody before changing its single-recipient
   policy.
6. Enable branch/ruleset protection for `ORESoftware/ores-sops` `main` with the
   keyless gates required.

This report intentionally does not include decrypted values, private identity
material, or ciphertext contents.