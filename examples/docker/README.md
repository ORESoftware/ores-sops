# Decrypting secrets in containers

Decrypt at **`docker run`**, never at `docker build`.

A secret decrypted during a build is written into an image layer and stays
there. Deleting it in a later `RUN` does not remove it — layers are immutable
and the earlier one is still in the image. Anyone who can pull the image can
recover it, and `--build-arg` is worse still, since it is recorded in
`docker history`. So the image carries only ciphertext, and the key arrives at
run time.

## Shape

```
image  = app + sops + env/enc/<name>.env.enc     (ciphertext, safe to push)
run    = docker run -e SOPS_AGE_KEY=...          (key, never in the image)
```

`ENTRYPOINT` is a shell script that decrypts into its own environment and then
`exec "$@"`s the real command, which is `CMD`:

```dockerfile
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["your-app", "--serve"]
```

Because `ENTRYPOINT` always runs, `docker run image some-other-command` still
gets the secrets.

## Four things this gets right

**The app becomes PID 1, so it can shut down gracefully.** The obvious
implementation is `exec sops exec-env FILE "your-app"`, and it is wrong: the app
runs as a *child* of sops, sops holds PID 1, and it does not forward signals. On
`docker stop` sops dies and the app never sees `SIGTERM` — no draining, no
flush. Verified: with that form, a `trap ... TERM` in the app never fires. This
entrypoint instead loads the values into its own shell and `exec`s, so the app
replaces the shell:

```
pid=1 comm=your-app     # not sops
```

(sops ≥ 3.9 has `--same-process` which also fixes this, but Alpine ships 3.8.1
and rejects the flag with `flag provided but not defined: -same-process`.)

**Secret values cannot execute code.** Values are parsed with `read` and
`export`, never `eval`. Under `eval`, a value containing `$(...)` or a backtick
runs as a command — which would turn read access to the secrets file into
arbitrary code execution inside the container. Verified: a value of
`$(touch /tmp/PWNED; echo pwned)` arrives as that literal string and creates no
file.

**Values containing `=` survive.** Splitting on the first `=` only keeps URLs,
base64 and JWTs intact: `postgres://u:p@h:5432/db?x=1` comes through whole.

**Plaintext never touches the filesystem.** `sops --decrypt` writes to stdout
and the value lives only in the entrypoint shell's memory.

## The filename detail that will bite you

`sops exec-env` has **no `--input-type` flag** — it infers the format from the
file extension. A file named `prod.env.enc` has extension `.enc`, so sops tries
to parse it as JSON and fails:

```
Could not unmarshal input data: invalid character 'D' looking for beginning of value
```

The repo keeps the `.env.enc` name because the gitignore rules depend on it, so
the Dockerfile copies it to a `.env` name inside the image:

```dockerfile
COPY env/enc/prod.env.enc /app/secrets/app.env
```

This entrypoint uses `sops --decrypt --input-type dotenv` explicitly, which has
the flag and does not care about the name — but the rename keeps the file
readable by `sops exec-env` too, and costs nothing.

## Getting the key in

| Method | Use when |
| --- | --- |
| `-e SOPS_AGE_KEY="$(cat keys.txt)"` | Simplest; how most orchestrators inject secrets |
| `SOPS_AGE_KEY_FILE=/run/secrets/age.key` + mount | Platform has a real secret store; key lands on tmpfs, and unlike an env var it is not exposed in `docker inspect` |
| KMS (`sops` supports AWS/GCP/Azure) | Cloud deploys — the instance role decrypts, so no key is shipped at all. Strongest option; change `.sops.yaml`, not this entrypoint. |

## Kubernetes

The same entrypoint works unchanged. Supply the key from a `Secret`:

```yaml
env:
  - name: SOPS_AGE_KEY
    valueFrom:
      secretKeyRef: { name: sops-age-key, key: key }
```

If you would rather not hand the key to the app container at all, decrypt in an
`initContainer` into an `emptyDir` with `medium: Memory`, and mount that into
the app — the app then reads a plain file and never has the key. For a cluster
that already runs it, the External Secrets Operator or `sops-nix` covers the
same ground; this entrypoint is the portable option that needs neither.

## Try it

```sh
export SOPS_AGE_KEY="$(cat ~/.config/sops/age/keys.txt)"
docker build -t demo .
docker run --rm -e SOPS_AGE_KEY demo
```
