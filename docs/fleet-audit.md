# Keyless fleet conformance audit

`ores-sops-fleet-audit` reports SOPS dotenv adoption without a decryption
identity. It is a rollout and policy-conformance scanner, not secret discovery.

## Supported contracts

The v0.4 scanner recognizes both:

```text
legacy: dev + prod
stage-enabled: dev + stage + prod
```

Dev and prod exact rules are required. One exact stage rule is optional. A
tracked `env/enc/stage.env.enc` without that rule is conflicting, not an
extension point. `staging`, `qa`, wildcard paths, and other `env/enc/*` files are
unexpected.

## Data boundary

The default scanner reads only:

- tracked path names and Git modes;
- `.gitignore` behavior for synthetic path names;
- the canonical ciphertext `.gitattributes` rule;
- exact SOPS `path_regex` declarations in `.sops.yaml`.

It does not decrypt, require a private identity, read dotenv values, emit
ciphertext payloads, or hash/inventory application values.

`--provider-inventory` additionally parses only variable names before `=` from
tracked canonical ciphertext blobs. It reports provider presence as plus-joined
environments, such as:

```text
none
dev
stage
prod
dev+stage
stage+prod
dev+stage+prod
```

The scanner never emits the corresponding values.

`--consumer-bypass` counts tracked Just/shell lines that create or chmod
`env/dec` before `ores-sops ensure-dec` can reject a symlink. It never prints the
matching recipe bodies. It also classifies `.dockerignore` as `ok`, `partial`,
`missing`, `untracked`, or `invalid`.

Canonical policy files must be tracked. Untracked local `.sops.yaml`,
`.gitignore`, or `.gitattributes` files cannot make a dirty working tree appear
adopted.

## Usage

```sh
nix run .#fleet-audit -- /path/to/repo-a /path/to/repo-b

# or inside nix develop
ores-sops-fleet-audit ../repo-a ../repo-b
```

Default TSV columns:

```text
repository  status  tracked_plaintext  unexpected_env_enc  tracked_symlinks  sops_rules  ignore_contract  ciphertext_attributes
```

Provider inventory:

```sh
ores-sops-fleet-audit --provider-inventory ../repo-a ../repo-b
```

Consumer-boundary inventory:

```sh
ores-sops-fleet-audit --consumer-bypass ../repo-a ../repo-b
```

Both flags may be combined. `--strict` exits nonzero unless every scanned
repository is adopted, while still printing the full report.

## Statuses

- `adopted`: tracked exact dev/prod rules, optional exact stage rule, matching
  tracked ignore behavior, canonical attributes, and no path conflict.
- `not-adopted`: no SOPS dotenv adoption signal was found.
- `partial`: some tracked adoption signal exists but the contract is incomplete;
  this includes a stage rule whose ciphertext allowlist was not added.
- `conflicting`: tracked plaintext, unexpected `env/enc/*`, stage ciphertext
  without the stage rule, a tracked symlink policy/ciphertext path, or a
  broad/duplicate/noncanonical rule was found.

The `sops_rules` label remains `exact` for both valid two- and three-environment
policies so existing fleet consumers retain a stable schema.

## Stage examples

Valid stage policy state:

```yaml
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age: [public recipients omitted]
  - path_regex: ^env/enc/stage\.env\.enc$
    age: [public recipients omitted]
  - path_regex: ^env/enc/prod\.env\.enc$
    age: [public recipients omitted]
```

Corresponding ignore exceptions:

```gitignore
/env/enc/*
!/env/enc/dev.env.enc
!/env/enc/stage.env.enc
!/env/enc/prod.env.enc
```

A stage rule without the stage allowlist is partial. A tracked stage ciphertext
without the exact stage rule is conflicting.

## Rollout workflow

A fleet controller should:

1. exclude archived, transferred, and superseded repositories;
2. scan without private identities;
3. route conflicting repositories for semantic review rather than rewriting;
4. preserve valid legacy dev/prod repositories;
5. opt repositories into stage only with the helper, policy, allowlist, access
   audit, and negative decrypt tests together;
6. run repository-specific build, archive, and platform checks before merge.

This scanner is intentionally narrower than a generic secret scanner. Secret
scanning remains a separate defense.
