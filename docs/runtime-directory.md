# `env/dec` runtime-directory contract

`env/dec/` contains decrypted dotenv material. It is intentionally absent from
Git because empty directories are not tracked and plaintext must never be
committed.

Every entry point that can invoke Nix, SOPS, or Just must therefore prepare the
local directory before doing any environment work:

```sh
mkdir -p env/dec
chmod 700 env/dec
```

The canonical Nix integration does this through `ores-sops.lib.prepareEnvDec`,
which is included automatically by `ores-sops.lib.shellHook`. It resolves the
repository root before creating the directory and refuses to follow a symlinked
`env` or `env/dec` path.

For repositories with direct Just recipes, use one private dependency and make
all environment recipes depend on it:

```just
[private]
_env-prepare:
    #!/usr/bin/env bash
    set -euo pipefail
    root={{ justfile_directory() }}
    [[ ! -L "$root/env" && ! -L "$root/env/dec" ]]
    mkdir -p "$root/env/dec"
    chmod 700 "$root/env/dec"

env-decrypt *names: _env-prepare
    # ...

env-encrypt *names: _env-prepare
    # ...
```

A repository audit must enforce both halves of the contract:

- `env/dec/` is ignored and has no tracked files;
- local `env/dec/` is recreated with mode `0700` whenever tooling starts.

Decrypted files below it remain mode `0600`.
