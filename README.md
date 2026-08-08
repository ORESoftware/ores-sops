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

Because the tracked files end in `.enc`, SOPS cannot infer the dotenv store from the filename. Every operation therefore uses explicit `--input-type dotenv --output-type dotenv`; encryption also uses `--filename-override env/enc/<dev|prod>.env.enc` so exact `.sops.yaml` creation rules are selected deterministically. Data-key rotation keeps the same explicit input/output typing so the rotated `.env.enc` remains dotenv-serialized.

## Required ignore policy

`ores-sops init` installs this deny/allow contract:

```gitignore
# Plaintext dotenv is local-only at every depth, including common suffix variants.
*.env
*/*.env
*/**/*.env
.env.*
*.env.*
!.env.example

# Decrypted material is never tracked.
/env/dec/

# Only the two approved ciphertext files are trackable.
/env/enc/*
!/env/enc/dev.env.enc
!/env/enc/prod.env.enc
```

The explicit nested patterns are retained even though Git can cover some cases with broader patterns; the redundancy makes the policy easy to audit and directly encodes the organization requirement. The exact ciphertext exceptions come after the broad `*.env.*` rule intentionally.

`ores-sops verify` uses `git check-ignore --no-index` and NUL-safe tracked-path enumeration to prove that plaintext is ignored and no unexpected path under `env/enc/` is tracked.

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
ores-sops diff dev|prod
ores-sops status
ores-sops refresh
ores-sops verify
ores-sops precommit
ores-sops lock
ores-sops install-hooks
```

`diff` is deliberately non-secret: it reports only variable names prefixed with `+` (added), `-` (removed), or `~` (value changed). It hashes values internally for comparison and never prints them.

Arbitrary environment names are rejected. This is intentional: the tracked VCS contract is exactly `dev` and `prod`.

## Atomic activation and failure behavior

`use` decrypts into an owner-only temporary file under `env/dec/`, validates successful SOPS completion and dotenv syntax/duplicate keys, applies mode `0600`, and only then atomically renames it into `env/dec/dev.env` or `env/dec/prod.env`. The managed `env/dec` directory is mode `0700` on POSIX platforms.

A failed decrypt therefore leaves the previous complete plaintext untouched. After a successful decrypt, the root symlink is replaced atomically with a relative link.

The helper fingerprints plaintext it created. If a developer hand-edits the decrypted file, `use` and `refresh` do not silently overwrite those edits. `use --force` is the explicit discard operation.

Managed env paths, ciphertext/plaintext files, policy files, and Git hook files/directories are rejected when repository-controlled symlinks could redirect the helper outside the intended boundary. A custom `core.hooksPath` is refused unless explicitly reviewed and opted in.

## SOPS policy

`init` creates separate exact creation rules for dev and prod. For bootstrap convenience both initially use the local public age recipient. **That is a pilot default, not the production access policy.**

Before production reliance:

- give humans individual identities rather than sharing a private age key;
- keep dev and prod recipient sets separate;
- protect CI identities and never expose them to fork-originated pull requests;
- prefer OIDC-backed KMS/workload identity for production CI where available;
- maintain independently controlled recovery paths;
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

- root, nested, and common-suffix plaintext dotenv ignore behavior;
- exact ciphertext allowlisting;
- no tracked plaintext dotenv paths;
- no unexpected tracked files below `env/enc/`;
- exact dev/prod SOPS path rules and no broad env/enc rules;
- policy/ciphertext paths are not tracked symlinks;
- managed root symlink target safety;
- `0700` decrypted directory and `0600` local decrypted files;
- SOPS ciphertext structure and absence of obvious plaintext assignments when ciphertext exists;
- tracked private-key material is rejected without echoing the matched line.

## Keyless fleet audit

`ores-sops-fleet-audit` classifies local repository clones without a decryption identity:

```sh
nix run .#fleet-audit -- ../repo-a ../repo-b
# or from nix develop:
ores-sops-fleet-audit ../repo-a ../repo-b
```

The TSV report contains only repository basename, adoption status, tracked violation counts, and policy-state labels. It does **not** decrypt or read dotenv/ciphertext values, hash/inventory application values, or print remote URLs.

Statuses are `adopted`, `not-adopted`, `partial`, and `conflicting`. Canonical policy files must be tracked; untracked local policy cannot make a dirty working tree look compliant. `--strict` exits non-zero unless every scanned repository is adopted.

See [`docs/fleet-audit.md`](docs/fleet-audit.md) for the data boundary and rollout workflow.

## Git hooks

`ores-sops install-hooks` installs managed `post-merge`, `post-checkout`, and `post-rewrite` refresh hooks plus a `pre-commit` guard.

The pre-commit hook blocks:

- root or nested plaintext dotenv files, even when force-added;
- any tracked `env/enc/*` path other than `dev.env.enc` and `prod.env.enc`;
- tracked symlink forms of managed policy/ciphertext paths.

Existing unmanaged hooks are left untouched rather than overwritten.

## Containers and CI

Do not decrypt during `docker build`; build layers are persistent. Inject secrets at runtime or use SOPS process execution where appropriate.

CI pull-request checks should remain keyless. Decryption identities belong only in protected trusted workflows/environments. Never rely on log masking as permission to print secret material.

The repository's platform certification runs the full Nix/SOPS/age/Bats/ShellCheck suite on Linux and macOS and separately verifies the native relative-symlink prerequisite on Windows.

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

The default package pins SOPS, age, Git, and shell dependencies. The flake also exposes `packages.ores-sops-fleet-audit` / `apps.fleet-audit`. The development shell includes both commands plus Bats and ShellCheck.

## Tests

```sh
nix develop --command bats tests/
nix flake check -L
```

The regression suite covers the exact allowlist, nested/suffixed plaintext rejection, dev/prod name restriction, SOPS ciphertext shape, relative symlinking, atomic failure preservation, local-edit protection, unmanaged `.env` refusal, cleanup safety, non-secret diff behavior, generated dev/prod/recovery lifecycle, offboarding/data-key rotation, policy verification, platform certification, and keyless fleet-audit classifications including unreadable secret-looking fixtures that the audit must not echo.
