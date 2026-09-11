# Environment-scoped SOPS + age access control

## Decision

Access is granted per ciphertext file. An age public recipient must not
implicitly appear on every environment.

The v0.4 application-dotenv contract is:

```text
env/enc/dev.env.enc
env/enc/stage.env.enc   # optional exact environment
env/enc/prod.env.enc
```

The corresponding plaintext paths are local-only:

```text
env/dec/dev.env
env/dec/stage.env
env/dec/prod.env
```

A developer who is approved only for dev may clone the repository and see the
three encrypted blobs, but their private age identity must decrypt only
`dev.env.enc`. It must fail on stage and prod. A successful decrypt is the only
path by which `ores-sops` writes the corresponding file under `env/dec/`.

## Cryptographic boundary

Each SOPS ciphertext has its own random data-encryption key. That file key is
wrapped separately for the public age recipients configured on the exact
creation rule. A normal `age:` list is one-of-many:

- Alice can decrypt a file when Alice's matching public recipient is listed;
- cloning ciphertext does not grant decryption;
- being listed on dev does not grant stage or prod;
- a recipient listed on multiple files can decrypt each of those files;
- a shared recovery identity can decrypt all three only because it is listed on
  all three deliberately.

Public `age1...` recipients are safe to commit and review. Private
`AGE-SECRET-KEY-...` identities must stay on the human device, hardware token,
protected workload, KMS integration, or secret manager. They must never enter
Git, issues, pull requests, Linear, logs, caches, artifacts, screenshots, or
fixtures.

## Recommended matrix

| Identity class | dev | stage | prod | Notes |
| --- | ---: | ---: | ---: | --- |
| ordinary developer | yes | no | no | Individual human identity |
| release engineer | yes | yes | no | Can test releases but cannot decrypt prod |
| production-authorized engineer | yes | yes | yes | Explicitly privileged on each file |
| dev CI | yes | no | no | Never expose to fork-originated PRs |
| stage deploy workload | no | yes | no | Separate protected workload identity |
| prod deploy workload | no | no | yes | Prefer OIDC-backed KMS/workload identity |
| break-glass recovery | yes | yes | yes | Offline, independent, and regularly tested |

The baseline three-environment audit requires at least one **true dev-only**
recipient—absent from both stage and prod. `--require-stage-exclusive` requires
at least one stage recipient omitted from prod. `--require-prod-exclusive`
requires a true production-only recipient omitted from dev and stage.

Production-authorized people may still be listed on all three. The strict checks
prove that less-privileged identities also exist and remain bounded.

## Canonical policy

Replace placeholders with real public recipients:

```yaml
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1_DEV_DEVELOPER_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_DEV_CI_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
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

Do not use `staging`, `qa`, wildcard `env/enc` rules, or arbitrary environment
names. Existing dev/prod repositories remain valid when no stage rule or stage
material exists.

## Bootstrap with scoped recipients

```sh
ores-sops init \
  --with-stage \
  --stage-recipient age1_STAGE_PUBLIC_RECIPIENT \
  --prod-recipient age1_PROD_PUBLIC_RECIPIENT \
  --recovery-recipient age1_RECOVERY_PUBLIC_RECIPIENT
```

When a scoped option is used, the local identity starts as dev-only. It is added
to stage or prod only when its public recipient is supplied for that environment
explicitly.

Available options:

```text
--recipient K           common/legacy recipient on every configured environment
--dev-recipient K       dev only
--stage-recipient K     stage only and enables stage
--prod-recipient K      prod only
--recovery-recipient K  all configured environments
```

Legacy `ores-sops init` remains a compatibility bootstrap and initially uses the
local recipient on dev/prod. That is not an acceptable final production matrix.

## Required gate

For a three-environment repository:

```sh
ores-sops verify

ores-sops-access-audit check \
  --require-stage \
  --require-stage-exclusive \
  --require-ciphertext
```

When a production-only identity is policy:

```sh
ores-sops-access-audit check \
  --require-stage \
  --require-stage-exclusive \
  --require-prod-exclusive \
  --require-ciphertext
```

Before ciphertext exists, use the explicit bootstrap-only mode:

```sh
ores-sops-access-audit check \
  --require-stage \
  --require-stage-exclusive \
  --policy-only
```

The audit does not decrypt. It reads `.sops.yaml` and only public
`sops_age__list_*__map_recipient` metadata from existing ciphertext. Normal
output reports counts, not recipient strings. `show` is the explicit public
recipient inventory command.

## Desired policy versus actual access

Creation rules are desired state. Existing ciphertext retains its current
wrapped-recipient metadata until the file is updated. Removing Alice from
`.sops.yaml` alone does not revoke Alice from the current ciphertext.

Synchronize only the changed environment:

```sh
ores-sops sync-keys stage
```

Equivalent direct command:

```sh
sops updatekeys -y --input-type dotenv env/enc/stage.env.enc
```

The access audit compares desired and actual public recipient sets and fails on
drift. Tests also hash the unaffected environment ciphertexts to prove a stage
recipient change does not rewrite dev or prod.

## Onboarding

1. Generate an individual age identity locally or issue an approved
   hardware-backed identity.
2. Send only the public `age1...` recipient to the policy owner.
3. Add it to exactly the approved environment rules.
4. Review `.sops.yaml` as an access-control change.
5. Run `ores-sops sync-keys` only for affected ciphertexts.
6. Run the required access audit and normal verification.
7. In a trusted test, prove positive access and expected negative access without
   printing any values.

For a dev-only person, the acceptance test is:

```text
dev decrypt:   success
stage decrypt: failure
prod decrypt:  failure
```

## Offboarding and compromise

1. Remove the public recipient from each affected rule.
2. Run `ores-sops sync-keys` for each affected current ciphertext.
3. Prove the removed identity cannot decrypt the current files.
4. When warranted, rotate the per-file SOPS data key:

   ```sh
   sops --rotate --in-place \
     --input-type dotenv \
     --output-type dotenv \
     env/enc/prod.env.enc
   ```

5. Rotate database passwords, API tokens, signing keys, and other application
   credentials whenever the removed identity may have learned them.
6. Remove GitHub, cloud, VPN, CI, shell, and secret-manager permissions
   separately.

SOPS rekeying controls future/current ciphertext access. It cannot erase
plaintext already learned, and historical Git revisions may remain decryptable
to identities authorized at the time.

## Runtime plaintext boundary

`env/dec/` is ignored, mode `0700`, and runtime-only. Completed files use mode
`0600`. Decryption occurs into an owner-only temporary file and is atomically
renamed only after SOPS and dotenv validation succeed. A failed stage or prod
decrypt therefore does not create a partial plaintext file and does not replace
a prior complete one.

`ores-sops use stage` creates only `env/dec/stage.env` and then atomically points
`.env` to that relative path. `ores-sops lock` removes all managed dev, stage,
and prod plaintext plus stale managed temp state.

Filesystem modes protect plaintext after decryption but do not replace the SOPS
recipient policy. On NixOS, `sops-nix` owner/group/mode settings are an
additional runtime ACL for service processes.

## CI identities

Use separate protected workload identities for dev, stage, and prod. A dev CI
identity must not decrypt stage/prod, and a stage deployment identity must not
decrypt prod. Never make any decryption identity available to fork-originated
pull requests.

Keyless PR checks should run `ores-sops verify` and the access audit. Trusted,
protected jobs may additionally verify decryptability and application startup,
but must clean plaintext in an always-run finalizer and never cache or upload it.

## Threshold policies

A plain age list is OR access. When production requires two independent trust
domains, SOPS `key_groups` plus a Shamir threshold can require, for example, one
human-controlled group and one workload/KMS-controlled group.

That is a separate policy class with different recovery risks. The age-list
access audit fails closed on `key_groups` rather than claiming that a simple
recipient-matrix check proves threshold behavior.

## Governance

Public recipient changes can grant decryption rights even though the recipient
strings are not secrets. Protect `.sops.yaml`, stage/prod ciphertext, the access
audit, and deployment workflows with CODEOWNERS plus an enforced branch
ruleset. CODEOWNERS alone does not force review unless repository protection
requires code-owner approval.
