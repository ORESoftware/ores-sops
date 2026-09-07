set shell := ["bash", "-euo", "pipefail", "-c"]

default: audit

# Validate the exact Git index and the SOPS/Age/Nix/Just policy anchors.
audit:
    python3 tools/audit_env_contract.py

# Exercise the adversarial encrypted-environment contract suite.
test-contract:
    python3 -m unittest discover -s test -p 'test_audit_env_contract.py' -v

# Create the ignored env/dec runtime boundary without decrypting or selecting an
# environment. The ores-sops helper rejects symlink redirection.
ensure-dec:
    ./ores-sops ensure-dec

# Reviewable ciphertext belongs only under env/enc. This tooling repository's
# root .sops.yaml is deny-closed and intentionally matches no real path.
list-encrypted:
    @if [[ -d env/enc ]]; then find env/enc -type f -name '*.env.enc' -print | LC_ALL=C sort; fi

# Prove plaintext/decrypted paths remain ignored before any local activation.
check-ignore:
    git check-ignore --quiet .env
    git check-ignore --quiet env/dec/runtime.env
