# Keyless fleet conformance audit

`ores-sops-fleet-audit` reports SOPS dotenv adoption state without a decryption identity.

It is intended for fleet rollout planning, not secret discovery.

## Data boundary

The scanner reads only:

- Git tracked path names and file modes;
- `.gitignore` behavior for synthetic path names;
- the presence of the canonical ciphertext `.gitattributes` rule;
- SOPS `path_regex` policy declarations in `.sops.yaml`.

It does **not**:

- decrypt ciphertext;
- read dotenv values;
- read ciphertext values;
- hash or inventory application values;
- require an age/KMS/private identity;
- print matched secret content.

The canonical policy files must themselves be **tracked**. Untracked local `.sops.yaml`, `.gitignore`, or `.gitattributes` files classify as partial adoption so a dirty working tree cannot make a repository appear compliant when a fresh clone is not.

## Usage

Audit one or more local clones:

```sh
nix run .#fleet-audit -- /path/to/repo-a /path/to/repo-b
```

Or from the development shell:

```sh
ores-sops-fleet-audit ../repo-a ../repo-b
```

The default report is TSV:

```text
repository  status  tracked_plaintext  unexpected_env_enc  tracked_symlinks  sops_rules  ignore_contract  ciphertext_attributes
```

`--strict` exits non-zero unless every scanned repository is fully adopted. It returns a higher failure code for a conflicting repository than for a merely partial/not-adopted repository, while still printing the complete report.

## Statuses

- `adopted`: tracked exact dev/prod SOPS rules, tracked canonical ignore behavior, and tracked ciphertext line-ending attributes are present with no tracked path conflict.
- `not-adopted`: no SOPS dotenv adoption signal was found.
- `partial`: some adoption signal exists, but the tracked contract is incomplete; this includes canonical-looking policy files that exist only in the local working tree.
- `conflicting`: tracked plaintext dotenv, an unexpected `env/enc/*` path, a tracked symlink policy/ciphertext path, or a broad/noncanonical `env/enc` SOPS rule was found.

The report uses counts and policy-state labels rather than file contents. Repository labels are local checkout basenames so credentials embedded in unusual remote URLs cannot be echoed accidentally.

## Rollout workflow

A fleet controller can use the report to:

1. exclude archived, transferred, or superseded repositories before mutation;
2. prioritize `not-adopted` repositories that already use `.env.example`, Nix, or flags-2-env;
3. route `conflicting` repositories for human/agent review rather than rewriting them automatically;
4. apply the canonical scaffold in small batches;
5. run repository-specific parser, build, archive, and platform tests before merging each adoption PR.

This scanner is deliberately narrower than a generic secret scanner. Secret scanning remains a separate defense; the fleet audit answers only whether repositories conform to the ORESoftware SOPS dotenv path and policy contract.

Tracking: DEN-2889 under DEN-2641.
