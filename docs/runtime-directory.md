# `env/dec` runtime-directory contract

`env/dec/` contains decrypted dotenv material. It is intentionally absent from
Git because empty directories are not tracked and plaintext must never be
committed.

The normative consumer rule is in [`consumer-boundary.md`](consumer-boundary.md):
callers must **not** `mkdir`, `chmod`, or otherwise touch `env/dec` before
delegating to `ores-sops`. A pre-existing symlink can redirect those operations
before the helper has a chance to refuse them.

## Canonical creation

Every managed `ores-sops` command and the exported Nix `shellHook` create the
directory through `ores-sops ensure-dec`. That path:

- rejects symlink or non-directory forms of `env`, `env/enc`, and `env/dec`;
- creates `env/dec` only after that check;
- enforces mode `0700`.

Just recipes should depend on the helper, not recreate the directory:

```just
[private]
_env-prepare:
    ores-sops ensure-dec

env-decrypt *names: _env-prepare
    ores-sops use {{ names }}
```

## Nix fallback

`ores-sops.lib.prepareEnvDec` is a Nix-shell fallback for the case where the
`ores-sops` binary is not yet on `PATH`. `lib.shellHook` prepends it, then
still calls `ores-sops ensure-dec` when the helper is available.

The fallback resolves the repository root, refuses a symlinked `env` or
`env/dec` path, and otherwise creates `env/dec` with mode `0700`. It is not a
license for consumer Justfiles or Dockerfiles to `mkdir -p env/dec` themselves.

## Audit

A repository audit must enforce both halves of the contract:

- `env/dec/` is ignored and has no tracked files;
- local `env/dec/` is recreated with mode `0700` by `ores-sops ensure-dec`
  (or the Nix shell hook), never by an unguarded caller `mkdir`.

Decrypted files below it remain mode `0600`.
