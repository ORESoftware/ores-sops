set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Validate the exact Git index and the SOPS/Age/Nix/Just policy anchors.
audit:
    python3 tools/audit_env_contract.py

# Exercise the adversarial encrypted-environment contract suite.
test-contract:
    python3 -m unittest discover -s test -p 'test_audit_env_contract.py' -v

# Prepare the ignored owner-only plaintext directory through the canonical guard.
ensure-dec:
    ./ores-sops ensure-dec

# List only reviewable ciphertext paths; values are never printed.
list-encrypted:
    @if [[ -d env/enc ]]; then find env/enc -type f -name '*.env.enc' -print | LC_ALL=C sort; fi

# Prove plaintext/decrypted paths remain ignored before local activation.
check-ignore:
    git check-ignore --quiet .env
    git check-ignore --quiet env/dec/runtime.env

# Activate one of the mandatory environment profiles.
use-dev:
    ./ores-sops use dev

use-prod:
    ./ores-sops use prod

# Explicitly discard local plaintext edits and restore managed ciphertext.
use-force-dev:
    ./ores-sops use --force dev

use-force-prod:
    ./ores-sops use --force prod

# Encrypt validated local plaintext back to the exact tracked ciphertext path.
encrypt-dev:
    ./ores-sops encrypt dev

encrypt-prod:
    ./ores-sops encrypt prod

# Edit through SOPS without exposing plaintext in command arguments.
edit-dev:
    ./ores-sops edit dev

edit-prod:
    ./ores-sops edit prod

# Report key-name changes only; values remain hidden.
diff-dev:
    ./ores-sops diff dev

diff-prod:
    ./ores-sops diff prod

status:
    ./ores-sops status

refresh:
    ./ores-sops refresh

verify:
    ./ores-sops verify

lock:
    ./ores-sops lock

install-hooks:
    ./ores-sops install-hooks

# Run the complete pinned Nix/SOPS/age/Bats/ShellCheck contract.
check:
    nix flake check -L
