# ores-sops

Repo-convention glue around [sops](https://github.com/getsops/sops). Org-agnostic.

Encrypted environment files live in git. The decrypted copy is a build artifact
that stays current on its own, including after a `git pull` changes it.

```
env/enc/prod.env.enc     committed sops ciphertext  <- source of truth
env/dec/prod.env         gitignored plaintext, 0600 <- generated
.env -> env/dec/prod.env gitignored symlink         <- what your app reads
```

## What this is not

It is not a sops wrapper. sops already does the hard parts, and this tool
deliberately does not re-expose them:

```sh
sops edit env/enc/prod.env.enc          # change a secret, no plaintext on disk
sops updatekeys env/enc/prod.env.enc    # after adding a recipient to .sops.yaml
sops exec-env env/enc/prod.env.enc cmd  # run a command with secrets, no file
age-keygen -o ~/.config/sops/age/keys.txt
```

What sops has no opinion about, and what this adds:

1. **The convention** — where ciphertext and plaintext live, and which one is active.
2. **Staying current** — re-decrypt when a merge brings in someone else's change.
3. **Not losing your work** — telling *"you edited it"* apart from *"upstream changed it"*.

Point 3 is the whole reason this is a program and not an alias. After a merge,
`plaintext != decrypt(ciphertext)`. When you hand-edit the plaintext, also
`plaintext != decrypt(ciphertext)`. Identical symptom, opposite correct
response: one must be overwritten, the other must never be. Comparing the two
files cannot distinguish them, so the plaintext is fingerprinted whenever this
tool writes it, and that fingerprint is the deciding fact.

## Use

You mostly do not run this. Git hooks call `refresh`; a repo's `justfile` or
devShell calls `use`.

```sh
ores-sops init            # scaffold env/, .sops.yaml, .gitignore rules
ores-sops use prod        # decrypt and point .env at it
ores-sops status          # per-environment state; * marks active
ores-sops lock            # wipe plaintext and the symlink when you are done
```

To change a secret, prefer `sops edit env/enc/prod.env.enc` — plaintext never
reaches the disk. For a bulk edit, edit `env/dec/prod.env` and then:

```sh
ores-sops diff prod       # what your edits would change
ores-sops encrypt prod    # fold them back into the ciphertext
```

Until you encrypt them, `use` and `refresh` refuse to overwrite your edits and
say so. `ores-sops use --force prod` discards them deliberately.

## Nix

```nix
{
  inputs.ores-sops.url = "github:ORESoftware/ores-sops";

  # in your devShell:
  devShells.default = pkgs.mkShell {
    packages = [ ores-sops.packages.${system}.default ];
    shellHook = ores-sops.lib.shellHook;   # installs hooks + refreshes
  };
}
```

`lib.shellHook` installs the git hooks and refreshes the active environment. It
deliberately does **not** pick an environment for you: auto-decrypting some
default would write live credentials to disk in a repo you only opened to read.
The first `use` is explicit; after that it keeps itself current.

An overlay (`overlays.default`) and `lib.forSystem <system>` are also exported.

## Git hooks

`ores-sops install-hooks` installs four hooks.

`post-merge`, `post-checkout` and `post-rewrite` call `refresh`. Git has no
`post-pull` hook — those three cover pull, branch switch, and rebase.

`pre-commit` is the one hook allowed to fail, with two severities:

- **BLOCK** — a plaintext env file is staged. There is no good reason for this
  and the cost of getting it wrong is a credential in git history forever, so
  the commit stops. (`git add -f` cannot sneak one past it.)
- **WARN** — `env/dec/<name>.env` differs from the `env/enc/<name>.env.enc` you
  are committing. Your input and your output disagree, which usually means you
  edited the plaintext and forgot `ores-sops encrypt`. It only warns: the commit
  may have nothing to do with secrets, and blocking it would be wrong.

The other three never fail the git operation. A hook that aborts your merge because a
secret could not be decrypted is worse than stale plaintext. They also leave any
pre-existing hook they did not write alone, and `.git/hooks` is not shared by
git, so each clone installs them once (the devShell hook does this).

## Containers

Decrypt at `docker run`, never at `docker build` — a secret decrypted during a
build is written into an image layer and stays there, recoverable by anyone who
can pull the image.

`ENTRYPOINT` is a shell script that decrypts into its own environment and then
`exec "$@"`s `CMD`, so the application becomes PID 1 and receives `SIGTERM`
directly. A working, tested example lives in
[`examples/docker/`](examples/docker/): Dockerfile, entrypoint, compose file,
and the reasoning — including why `exec sops exec-env your-app` looks right and
breaks graceful shutdown, why values are parsed with `read`/`export` rather than
`eval`, and the `sops exec-env` filename gotcha.

## Why dotenv, and what a reviewer sees

For dotenv files sops encrypts **values** and leaves variable **names** readable:

```
CLOUDFLARE_API_TOKEN=ENC[AES256_GCM,data:VK5LHYzn...,type:str]
```

A pull request therefore shows *which* variable changed without revealing what
it was set to, which keeps config changes reviewable.

## Adding a recipient

```sh
age-keygen -o ~/.config/sops/age/keys.txt   # on the new machine, prints its public key
# add that age1... to the age: list in .sops.yaml, then from a machine that can already decrypt:
sops updatekeys env/enc/prod.env.enc
```

Removing a recipient is the same minus the key — but treat every secret that key
could read as compromised and rotate it at the provider. Dropping a sops
recipient does not invalidate credentials it has already seen.

## Requirements

`sops`, `age`, `git`, and a POSIX shell. The nix package pins all of them into
its closure, which matters for git hooks: they run with a minimal PATH.

## Tests

```sh
nix develop --command bats tests/
nix flake check
```
