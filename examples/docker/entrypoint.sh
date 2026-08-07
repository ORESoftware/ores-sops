#!/bin/sh
# Container entrypoint: decrypt secrets at RUN time, then exec the real command.
#
# Pair with a Dockerfile that sets:
#   ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
#   CMD ["your-app", "--serve"]
#
# so this script receives the real command as "$@" and hands off to it with
# exec. Overriding the command (`docker run image other-cmd`) still gets the
# secrets, because ENTRYPOINT always runs.
#
# Decryption happens here and never at build time. A secret decrypted during
# `docker build` is baked into an image layer forever — `RUN rm` in a later
# layer does not remove it, and anyone who can pull the image can extract it.
# The image carries only ciphertext; the key arrives at `docker run`.

set -eu

# The *encrypted* file baked into the image. It is ciphertext, so shipping it is
# safe. Note the `.env` suffix: `sops exec-env` has no --input-type flag and
# infers the format from the file extension, so a file named `.env.enc` fails
# with "Could not unmarshal input data". The Dockerfile copies
# env/enc/<name>.env.enc to a *.env name for exactly this reason.
: "${SOPS_SECRETS_FILE:=/app/secrets/app.env}"

# No secrets file: run the command unchanged. Keeps the same image usable for
# `--help`, unit tests, and local runs that need no secrets.
if [ ! -f "$SOPS_SECRETS_FILE" ]; then
  exec "$@"
fi

# The key must be supplied at run time. SOPS_AGE_KEY carries the private key
# directly (the usual container path: an orchestrator secret); SOPS_AGE_KEY_FILE
# points at a mounted file. Fail loudly rather than starting a process that will
# misbehave later with empty config.
if [ -z "${SOPS_AGE_KEY:-}" ] && [ -z "${SOPS_AGE_KEY_FILE:-}" ]; then
  echo "entrypoint: no SOPS_AGE_KEY or SOPS_AGE_KEY_FILE set." >&2
  echo "  docker run -e SOPS_AGE_KEY=\"\$(cat ~/.config/sops/age/keys.txt)\" ..." >&2
  echo "  or mount a key and set SOPS_AGE_KEY_FILE=/run/secrets/age.key" >&2
  exit 1
fi

# Load the decrypted values into THIS shell, then exec the real command, so the
# application replaces this process and becomes PID 1.
#
# Deliberately not `sops exec-env`. That runs the command as a child of sops,
# which then owns PID 1 and does not forward signals: `docker stop` kills sops
# and the application never sees SIGTERM, so it gets no chance to drain
# connections or flush. Measured, not assumed — with sops as PID 1 a trap on
# TERM in the child never fires. (sops >= 3.9 has --same-process, which fixes
# this, but Alpine ships 3.8.1 and rejects the flag outright.)
#
# `sops -d` writes to stdout; the plaintext lives only in this shell's memory
# and never touches the filesystem.
#
# Parsed with `read` + `export`, never `eval`. A decrypted value containing
# `$(...)` or a backtick would be executed by eval — turning read access to the
# secrets file into arbitrary code execution in the container. `export "$k=$v"`
# assigns literally. Splitting on the first `=` only, via IFS, keeps values that
# themselves contain `=` (URLs, base64, JWTs) intact.
secrets=$(sops --decrypt --input-type dotenv --output-type dotenv "$SOPS_SECRETS_FILE") || {
  echo "entrypoint: failed to decrypt $SOPS_SECRETS_FILE" >&2
  exit 1
}

while IFS='=' read -r key value; do
  case "$key" in
    '' | '#'*) continue ;; # blank lines and sops' comment entries
  esac
  export "$key=$value"
done <<EOF
$secrets
EOF
unset secrets

exec "$@"
