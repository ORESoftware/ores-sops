# Environment-scoped SOPS + age access control

## Decision

An age public recipient must **not** automatically appear on every encrypted
environment file. Access is granted per ciphertext file by listing only the
approved recipients on that file's exact SOPS creation rule.

The v0.4 contract uses required development and production files plus one
optional, exact staging environment:

```text
env/enc/dev.env.enc
env/enc/stage.env.enc   # optional exact-rule opt-in
env/enc/prod.env.enc

# Runtime-only plaintext
env/dec/dev.env
env/dec/stage.env
env/dec/prod.env
```

A developer who is listed only on the dev rule can clone every ciphertext but
can decrypt only `dev.env.enc`. A stage-only identity cannot decrypt prod. A
shared recovery identity can decrypt multiple environments only because it is
explicitly listed on each of those rules.

## Recommended access matrix

| Identity class | dev | stage | prod | Notes |
| --- | ---: | ---: | ---: | --- |
| ordinary developer | yes | no | no | Individual human identity |
| release engineer | yes | yes | no | May promote to stage, not prod |
| production-authorized developer | yes | yes | yes | Explicit elevated mapping |
| dev CI workload | yes | no | no | Never expose to fork PRs |
| stage deploy workload | no | yes | no | Stage-only workload identity |
| prod deploy workload | no | no | yes | Prefer OIDC-backed KMS/workload identity |
| break-glass recovery | yes | yes | yes | Offline and independently controlled |

The same person may use one age identity on several approved files, but a
separate hardware-backed production identity reduces blast radius.

## How the cryptographic boundary works

Each SOPS file has its own random data-encryption key. SOPS encrypts the values
with that per-file key and wraps the key separately for every configured age
recipient or master key. A normal `age:` list is one-of-many: any listed private
identity can unwrap that file key. Being listed on one environment does not grant
access to another.

Public `age1...` recipients are safe to commit. Private `AGE-SECRET-KEY-...`
identities must remain on the developer device, hardware token, secret manager,
or protected workload and must never enter Git, issues, pull requests, logs,
artifacts, caches, screenshots, or chat.

## Canonical `.sops.yaml` pattern

Replace placeholders with real public recipients:

```yaml
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1_DEV_ALICE_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RELEASE_ENGINEER_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT

  - path_regex: ^env/enc/stage\.env\.enc$
    age:
      - age1_RELEASE_ENGINEER_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_STAGE_DEPLOY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT

  - path_regex: ^env/enc/prod\.env\.enc$
    age:
      - age1_PROD_OPERATOR_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_PROD_DEPLOY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
```

This matrix gives Alice only dev, the release engineer dev+stage, production
operators only the environments on which they are listed, and recovery all three.

## Scaffolding

Backward-compatible two-environment bootstrap:

```sh
ores-sops init
```

Three-environment scaffold with scoped recipients:

```sh
ores-sops init --with-stage \
  --local-scope dev \
  --dev-recipient age1... \
  --stage-recipient age1... \
  --prod-recipient age1... \
  --recovery-recipient age1...
```

`--recipient` remains the legacy/shared option and adds its recipient to every
configured environment. Prefer the scoped flags for new repositories.

## Desired policy versus actual ciphertext

`.sops.yaml` is desired state. Existing ciphertext retains its current wrapped
recipient metadata until the affected file is updated. Editing policy alone does
not grant or revoke access.

Apply a change to only the affected file:

```sh
ores-sops sync-keys dev
ores-sops sync-keys stage
ores-sops sync-keys prod

# Equivalent low-level command:
sops updatekeys -y --input-type dotenv env/enc/stage.env.enc
```

Then require exact desired-versus-actual agreement:

```sh
ores-sops verify
ores-sops-access-audit check --require-ciphertext
```

The access audit never decrypts. It reads `.sops.yaml` and only public
`sops_age__list_*__map_recipient` metadata from existing ciphertext. Normal
output reports counts, not recipient values.

With stage enabled, the audit requires:

- at least one dev-only recipient omitted from both stage and prod;
- at least one stage recipient omitted from prod;
- the configured recipient set on every ciphertext to match its exact rule;
- an optional production-only identity when `--require-prod-exclusive` is used.

## Onboarding

1. Generate an individual age identity locally or obtain an approved
   hardware-backed identity.
2. Supply only the public `age1...` recipient.
3. Add it to exactly the allowed environment rule or rules.
4. Review `.sops.yaml` and protected ciphertext changes under CODEOWNERS.
5. Run `ores-sops sync-keys <environment>` for each affected file.
6. Run the required-ciphertext access audit and normal verification.
7. Test positive and negative decryptability in a trusted environment without
   printing values.

## Offboarding and compromise

1. Remove the public recipient from every environment being revoked.
2. Run `ores-sops sync-keys <environment>` for each affected current ciphertext.
3. Prove the removed identity fails to decrypt those current files.
4. Rotate the SOPS data key when warranted:

```sh
sops --rotate --in-place \
  --input-type dotenv \
  --output-type dotenv \
  env/enc/prod.env.enc
```

5. Rotate application credentials whenever the person may have learned them.
6. Remove GitHub, CI, cloud, shell, VPN, and secret-manager access separately.

Old Git commits may remain decryptable to identities authorized for those old
revisions. Repository history is not a revocation system.

## Stronger production approval

A plain age list is OR authorization. SOPS `key_groups` with a Shamir threshold
can require multiple trust domains, such as an approved human group and a cloud
KMS/workload group. That is a separate availability and recovery policy. The
age-list access audit fails closed on `key_groups` rather than pretending it has
validated a threshold configuration.

## Nix, Just, GitHub, and sops-nix responsibilities

- **SOPS + age** decides who can decrypt each tracked file.
- **Nix** pins tool versions; it does not grant access.
- **Just** supplies reviewed recipes; it does not bypass cryptography.
- **GitHub permissions** control who can clone or modify ciphertext, not who can
  decrypt it.
- **CODEOWNERS and branch protection** should protect `.sops.yaml`, stage/prod
  ciphertext, and trusted deployment workflows.
- **sops-nix owner/group/mode** controls local plaintext access after a host has
  decrypted a secret; it is separate from the repository recipient matrix.
