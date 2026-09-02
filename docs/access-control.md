# Environment-scoped SOPS + age access control

## Decision

An age public recipient must **not** automatically appear on every encrypted
environment file. Access is granted per ciphertext file by listing only the
approved recipients on that file's exact SOPS creation rule.

The current `ores-sops` contract has two tracked secret-bearing files:

```text
env/enc/dev.env.enc
env/enc/prod.env.enc
```

They must use a least-privilege recipient matrix before production reliance. A
shared, independently controlled recovery recipient is allowed. The required
property is that at least one ordinary development recipient is omitted from
prod; otherwise every developer who can decrypt dev can also decrypt prod.

Production-authorized developers may deliberately be listed on both files, so a
prod recipient set contained within dev is valid. Repositories that require a
separate hardware or workload identity used only for production can enable the
stricter production-exclusive check:

```sh
nix run github:ORESoftware/ores-sops#access-audit -- check
nix run github:ORESoftware/ores-sops#access-audit -- \
  check --require-prod-exclusive

# Or, inside nix develop:
ores-sops-access-audit check
```

The audit reads only `.sops.yaml`. It does not decrypt, open ciphertext, or read
private identity files.

## How the cryptographic boundary works

Each encrypted SOPS file has its own random data-encryption key. SOPS wraps that
file key separately for every configured master key or age recipient and stores
the wrapped copies in the file metadata.

For a normal `age:` recipient list, access is **OR**:

- Alice's private age identity can decrypt a file if Alice's public recipient is
  listed for that file.
- Bob cannot decrypt that file merely because Bob can clone the repository or
  because Bob is listed on another environment's rule.
- A recipient listed on both dev and prod can decrypt both. This should be
  deliberate, normally for a tightly controlled recovery identity, a privileged
  developer, or an explicitly authorized production operator.

The public recipient is safe to commit. The corresponding private identity must
stay on the developer device, hardware token, secret manager, or protected
workload and must never enter Git, issues, pull requests, CI logs, artifacts, or
chat.

## Recommended human and workload matrix

| Identity class | dev | prod | Notes |
| --- | ---: | ---: | --- |
| ordinary developer | yes | no | Individual human age identity |
| production-authorized developer | yes | yes | Same identity may be mapped to both files |
| production-only operator | optional | yes | Prefer a separate hardware-backed identity |
| dev CI workload | yes | no | Never expose to fork-originated pull requests |
| prod deploy workload | no | yes | Prefer OIDC-backed KMS/workload identity where practical |
| break-glass recovery | yes | yes | Offline and independently controlled; test recovery |

A person can use one age keypair across multiple allowed files because the
recipient-to-file mapping still enforces the boundary. Separate production
hardware identities reduce blast radius further and are preferred for elevated
access, but they are not required for the common “some developers also operate
production” hierarchy.

## Canonical `.sops.yaml` pattern

Replace every placeholder with a real **public** age recipient. Do not put
private identities here.

```yaml
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1_DEV_ALICE_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_DEV_BOB_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_PROD_OPERATOR_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT

  - path_regex: ^env/enc/prod\.env\.enc$
    age:
      - age1_PROD_OPERATOR_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_PROD_DEPLOY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
```

This gives Alice and Bob development access without production access. The
production operator is deliberately listed on both files. The production deploy
workload is production-only, and the recovery identity can decrypt both by
explicit policy.

Creation rules are desired state for new encryption. Existing ciphertext keeps
its current wrapped recipient metadata until it is synchronized.

## Applying a recipient change

After changing one environment's recipient list, update only that ciphertext:

```sh
sops updatekeys -y --input-type dotenv env/enc/dev.env.enc
sops updatekeys -y --input-type dotenv env/enc/prod.env.enc
```

The operator running `updatekeys` must already have a private identity capable
of decrypting the current file key. The operation re-wraps that file key for the
new recipient set; it does not reveal application values in normal output.

For a removal caused by compromise or where a fresh file key is required:

```sh
# 1. Remove the public recipient from the exact .sops.yaml rule.
sops updatekeys -y --input-type dotenv env/enc/prod.env.enc

# 2. Generate a new per-file data key and re-encrypt the values.
sops --rotate --in-place \
  --input-type dotenv \
  --output-type dotenv \
  env/enc/prod.env.enc
```

Then rotate the application credentials themselves whenever the removed person
or identity may have seen or used them. Rekeying SOPS prevents access to future
ciphertext revisions; it cannot make previously learned credentials unknown.
Old Git commits also remain decryptable to identities that were authorized for
those historical revisions, so repository history is not a revocation system.

## Onboarding

1. The developer generates an individual age identity locally or obtains an
   approved hardware-backed identity.
2. Only the public `age1...` recipient is supplied to the repository owner.
3. Add it to exactly the allowed environment rule or rules.
4. Review the access-policy change under protected ownership.
5. Run `sops updatekeys` only for the affected ciphertext files.
6. Run `ores-sops-access-audit check` and the normal `ores-sops verify` gate.
7. Test decryptability in a trusted environment without printing values.

## Offboarding

1. Remove the public recipient from each environment the person must no longer
   access.
2. Run `sops updatekeys` for each affected current ciphertext.
3. Prove the removed identity no longer decrypts the current files.
4. Rotate the SOPS data key when the access event warrants it.
5. Rotate application credentials whenever historical knowledge matters.
6. Remove GitHub, CI, cloud, shell, VPN, and secret-manager access separately;
   SOPS controls only the ciphertext decryption boundary.

## Stronger production approval with key groups

A plain `age:` list is one-of-many access. When production policy requires two
independent trust domains, SOPS key groups can split the file key with a Shamir
threshold. For example, requiring one approved human group **and** one cloud KMS
or protected workload group uses two groups with a threshold of two.

That is a different policy from simple environment separation. It should be
reviewed and tested separately because an unavailable group can make production
recovery impossible. The `ores-sops-access-audit` command intentionally fails
closed on `key_groups` rather than pretending an age-list audit proves a
threshold policy.

## Nix, Just, GitHub, and sops-nix responsibilities

- **SOPS + age** decides who can cryptographically decrypt each tracked file.
- **Nix** pins the `sops`, `age`, audit, and helper versions so behavior is
  reproducible. It does not grant decryption access.
- **Just** provides reviewed command recipes. It does not grant access either;
  an unauthorized identity still cannot decrypt.
- **GitHub repository permissions** decide who can read or modify Git data.
  Cloning ciphertext is not decryption authorization.
- **CODEOWNERS and branch protection** should protect `.sops.yaml`, production
  ciphertext, and trusted deployment workflows from unauthorized policy
  changes.
- **sops-nix owner/group/mode settings** control which processes or users can
  read a plaintext file after a host decrypts it. That runtime ACL is separate
  from the SOPS recipient ACL stored with repository ciphertext.

## Stage environment status

The same model works for an exact third rule such as
`env/enc/stage.env.enc`: stage-only recipients are listed on that rule and are
omitted from prod. However, `ores-sops` v0.3.x intentionally enforces exactly
`dev` and `prod`; it rejects arbitrary or staging paths so a repository cannot
silently weaken the fleet contract.

Therefore, do not add `stage.env.enc` ad hoc. Stage support must land as a
versioned contract change that updates all of these together:

- accepted environment names and safe `.env` targets;
- exact Git allowlist and pre-commit checks;
- exact SOPS creation-rule verification;
- status, refresh, lock, temp cleanup, and symlink handling;
- Nix/Just examples and fleet audit;
- access-matrix tests proving dev-only and stage-only identities cannot decrypt
  prod;
- organization policy documentation and rollout compatibility.

Until that coordinated change lands, use the existing dev/prod split as the
enforced cryptographic boundary rather than inventing an unverified staging
path.
