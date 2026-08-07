# Runtime secret decryption with sops. Nothing is decrypted at build time.
#
# Build:  docker build -t myapp .
# Run:    docker run --rm -e SOPS_AGE_KEY="$(cat ~/.config/sops/age/keys.txt)" myapp
#
# The image contains ciphertext and the sops binary. The key never enters the
# image, is never a build arg, and is never a layer — it arrives at run time.

FROM alpine:3.20

# sops is the only extra runtime dependency. age is NOT needed: sops decrypts
# age-encrypted files itself, and the key comes in through SOPS_AGE_KEY.
RUN apk add --no-cache sops ca-certificates

WORKDIR /app

# Ship the ENCRYPTED file. This is ciphertext, so it is safe in a layer and safe
# in a registry.
#
# It is copied to a `*.env` name on purpose. `sops exec-env` has no
# --input-type flag and infers the format from the file extension, so a file
# still named `.env.enc` fails with "Could not unmarshal input data: invalid
# character". The repo keeps the `.env.enc` name because the gitignore rules
# depend on it; the image uses `.env` because sops' parser does.
COPY env/enc/prod.env.enc /app/secrets/app.env

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Run unprivileged. sops only needs to read the ciphertext and the key.
RUN adduser -D -u 10001 app && chown -R app:app /app
USER app

# ENTRYPOINT does the sops work and then execs CMD, so overriding the command
# still gets secrets.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sh", "-c", "echo \"DB_PASSWORD=$DB_PASSWORD\"; echo \"API_KEY=$API_KEY\""]
