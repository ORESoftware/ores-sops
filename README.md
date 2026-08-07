# ores-sops

`ores-sops` is the canonical ORESoftware repository convention around [SOPS](https://github.com/getsops/sops) for dotenv secrets.

## Contract

Exactly two secret-bearing ciphertext files are allowed in version control:

```text
env/enc/dev.env.enc
env/enc/prod.env.enc
```

Plaintext is local-only:

```text
env/dec/dev.env
env/dec/prod.env
.env -> env/dec/dev.env   # or prod
```

The root `.env` is a **relative managed symlink**, never a copied plaintext file. `ores-sops` refuses to overwrite or delete an unmanaged `.env` file or an unmanaged `.env` symlink.

Because the tracked files end in `.enc`, SOPS cannot infer the dotenv store from the filename. Every operation therefore uses explicit `--input-type dotenv --output-type dotenv`; encryption also uses `--filename-override env/enc/<dev|prod>.env.enc` so exact `.sops.yaml` creation rules are selected deterministically.

## Required ignore policy

`ores-sops init` installs this deny/allow contract:

```gitignore
# Plaintext dotenv is local-only at every depth.
*.env
*/*.env
*/**/*.env
.env.*
!.env.example

# Decrypted material is never tracked.
/env/dec/

# Only the two approved ciphertext files are trackable.
/env/enc/*
!/env/enc/dev.env.enc
!/env/enc/prod.env.enc
```

The explicit nested patterns are retained even though Git can cover some cases with broader patterns; the redundancy makes the policy easy to audit and directly encodes the organization requirement.

`ores-sops verify` uses `git check-ignore --no-index` and `git ls-files` to prove that plaintext is ignored and no unexpected path under `env/enc/` is tracked.

## Quick start

```sh
age-keygen -o ~/.config/sops/age/keys.txt

ores-sops init

# Create/edit the ignored dev plaintext, then encrypt it.
$EDITOR env/dec/dev.env
ores-sops encrypt dev
git add env/enc/dev.env.enc

# Activate dev later.
ores-sops use dev
# .env -> env/dec/dev.env

# Remove local plaintext when finished.
ores-sops lock
```

Prefer `ores-sops edit dev` or `ores-sops edit prod` for normal secret changes because SOPS edits ciphertext directly and avoids a durable plaintext editing workflow.

## Commands

```text
ores-sops init
ores-sops use dev|prod [--force]
ores-sops encrypt dev|prod [--allow-empty]
ores-sops edit dev|prod
ores-sops status
ores-sops refresh
ores-sops verify
ores-sops precommit
ores-sops lock
ores-sops install-hooks
```

Arbitrary environment names are rejected. This is intentional: the tracked VCS contract is exactly `dev` and `prod`.

## Atomic activation and failure behavior

`use` decrypts into an owner-only temporary file under `env/dec/`, validates successful SOPS completion, applies mode `0600`, and only then atomically renames it into `env/dec/dev.env` or `env/dec/prod.env`.

A failed decrypt therefore leaves the previous complete plaintext untouched. After a successful decrypt, the root symlink is replaced atomically with a relative link.

The helper fingerprints plaintext it created. If a developer hand-edits the decrypted file, `use` and `refresh` do not silently overwrite those edits. `use --force` is the explicit discard operation.

## SOPS policy

`init` creates separate exact creation rules for dev and prod. For bootstrap convenience both initially use the local public age recipient. **That is a pilot default, not the production access policy.**

Before production reliance:

- give humans individual identities rather than sharing a private age key;
- keep dev and prod recipient sets separate;
- protect CI identities and never expose them to fork-originated pull requests;
- prefer OIDC-backed KMS/workload identity for production CI where available;
- maintain an independently controlled recovery path;
- run `sops updatekeys` after recipient changes;
- rotate the SOPS data key and application credentials when offboarding or compromise requires revocation of future access.

Private identities, real secret values, service-account keys, and decrypted dotenv files must never appear in Git, Linear, GitHub issues/PR text, logs, caches, artifacts, examples, or fixtures.

## Verification

Keyless policy checks:

```sh
ores-sops verify
```

Trusted environments may additionally prove decryptability:

```sh
ORES_SOPS_VERIFY_DECRYPT=1 ores-sops verify
```

The keyless check validates:

- root and nested plaintext dotenv ignore behavior;
- exact ciphertext allowlisting;
- no tracked plaintext dotenv paths;
- no unexpected tracked files below `env/enc/`;
- exact dev/prod SOPS path rules;
- managed root symlink target safety;
- `0600` permissions for any local decrypted files;
- SOPS ciphertext structure when ciphertext exists.

## Git hooks

`ores-sops install-hooks` installs managed `post-merge`, `post-checkout`, and `post-rewrite` refresh hooks plus a `pre-commit` guard.

The pre-commit hook blocks:

- root or nested plaintext dotenv files, even when force-added;
- any tracked `env/enc/*` path other than `dev.env.enc` and `prod.env.enc`.

Existing unmanaged hooks are left untouched rather than overwritten.

## Containers and CI

Do not decrypt during `docker build`; build layers are persistent. Inject secrets at runtime or use SOPS process execution where appropriate.

CI pull-request checks should remain keyless. Decryption identities belong only in protected trusted workflows/environments. Never rely on log masking as permission to print secret material.

## Nix

```nix
{
  inputs.ores-sops.url = "github:ORESoftware/ores-sops";

  devShells.default = pkgs.mkShell {
    packages = [ ores-sops.packages.${system}.default ];
    shellHook = ores-sops.lib.shellHook;
  };
}
```

The package pins SOPS, age, Git, and shell dependencies. The development shell includes Bats and ShellCheck.

## Tests

```sh
nix develop --command bats tests/
nix flake check
```

The regression suite covers the exact allowlist, nested plaintext rejection, dev/prod name restriction, SOPS ciphertext shape, relative symlinking, atomic failure preservation, local-edit protection, unmanaged `.env` refusal, cleanup safety, and policy verification.
