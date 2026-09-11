# Encrypted environment security contract

This repository defines the minimum fail-closed contract for storing environment configuration in Git without storing decrypted secret material in Git.

## Canonical layout

- `env/enc/*.env.enc` contains only SOPS ciphertext with Age recipient metadata.
- `env/dec/` is the local decrypted working tree and is ignored recursively.
- Root `.env` files are ignored. Committable examples must end in `.example`, `.sample`, or `.template` and must contain non-secret placeholders only.
- `.sops.yaml` or `.sops.yml` owns creation rules and Age recipients.
- `flake.nix` makes SOPS and Age versions reproducible.
- `justfile` or `Justfile` exposes the reviewed encrypt/decrypt interface and keeps paths explicit.

## Threats rejected by CI

The repository audit fails on tracked plaintext/decrypted environment files, secret-path symlinks, executable encrypted files, malformed or oversized ciphertext files, non-canonical encrypted filenames, missing SOPS/Age policy anchors, and missing ignore rules.

The audit enumerates the Git index rather than walking only the working tree. This matters because an ignored local file is harmless to Git history, while a staged or already tracked file remains a disclosure risk even when a later ignore rule is added.

## Operational rules

1. Never commit an Age identity/private key. Only public recipients belong in policy.
2. Decrypt only into `env/dec/` with restrictive local permissions.
3. Re-encrypt after recipient rotation; do not hand-edit SOPS metadata.
4. Treat a ciphertext file that lacks SOPS and Age metadata as invalid, even when its extension says `.enc`.
5. Do not use symlinks in either encrypted or decrypted environment paths.
6. Keep production secret values out of examples, tests, logs, issue comments, and pull-request descriptions.
7. A plaintext secret disclosed in chat or Git history must be treated as exposed and rotated by an authorized owner; automation must not revoke or rotate credentials without explicit authorization.

## Consumer contract

Consuming repositories should pin an audited `ores-sops` release, reuse its Just/Nix entry points, and run the same index-based audit before merge. Product- or organization-specific encrypted values remain in that product's own `*-infra` repository; this repository owns reusable tooling and policy, not another organization's secret inventory.
