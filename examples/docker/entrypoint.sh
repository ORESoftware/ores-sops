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

# `sops exec-env` takes the command as ONE string and runs it through a shell;
# trailing arguments are not forwarded as positional parameters. So rebuild the
# argument vector as a single shell-quoted string. Each argument is wrapped in
# single quotes with embedded single quotes escaped, which survives spaces,
# quotes, globs and $ in argument values.
quoted=''
for arg in "$@"; do
  escaped=$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")
  quoted="$quoted '$escaped'"
done

# --same-process replaces this process rather than forking, so the application
# becomes PID 1 and receives SIGTERM from `docker stop` directly. Without it
# sops sits between the init signal and the app, and stops become 10s timeouts.
#
# It is detected rather than assumed: the flag is absent from older sops builds,
# including the one in Alpine's repositories, where passing it aborts with
# "flag provided but not defined: -same-process". Detecting costs one exec at
# startup and keeps this entrypoint working on whatever sops the base image has.
same_process=''
if sops exec-env --help 2>&1 | grep -q -- '--same-process'; then
  same_process='--same-process'
fi

# The inner `exec` matters for the same reason: it stops the shell that sops
# spawns from lingering as the application's parent.
#
# shellcheck disable=SC2086 # $same_process is a deliberate empty-or-one-flag
exec sops exec-env $same_process "$SOPS_SECRETS_FILE" "exec $quoted"
