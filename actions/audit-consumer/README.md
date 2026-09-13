# ores-sops consumer audit action

This composite action runs the repository's canonical `tools/audit_env_contract.py` against the caller's checked-out repository. It is intentionally thin: downstream repositories receive the same fail-closed rules as this repository without copying the auditor.

Pin the action to an immutable commit SHA in consumers:

```yaml
permissions:
  contents: read

steps:
  - uses: actions/checkout@<full-commit-sha>
    with:
      persist-credentials: false
  - uses: ORESoftware/ores-sops/actions/audit-consumer@<full-commit-sha>
```

The caller must check out its repository first and provide Python 3. The audit reads tracked paths and local policy files only; it does not decrypt ciphertext or require Age/SOPS private keys.

`root` may select a repository-relative subdirectory, but it does not weaken the contract: the selected root must independently satisfy the encrypted-environment policy anchors.
