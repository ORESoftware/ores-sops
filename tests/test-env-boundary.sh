#!/usr/bin/env bash
# No provider calls, credentials, private age keys, or cryptographic assertions.
set +x
set -euo pipefail
source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
with_just=0
case "${1:-}" in '') ;; --with-just) with_just=1 ;; *) exit 2 ;; esac
if [ "$with_just" -eq 1 ]; then command -v just >/dev/null; fi
umask 077
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
trap 'exit 130' HUP INT TERM
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=env-test GIT_AUTHOR_EMAIL=env-test@example.invalid
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
mkdir -p "$HOME" "$tmp/bin"
export CALL_LOG="$tmp/calls" MARKER="$tmp/injected"
cat > "$tmp/bin/ores-sops" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' ores-sops "$@" >> "$CALL_LOG"
STUB
cat > "$tmp/bin/sops" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' sops "$@" >> "$CALL_LOG"
exit "${TEST_SOPS_STATUS:-0}"
STUB
chmod +x "$tmp/bin/ores-sops" "$tmp/bin/sops"
export PATH="$tmp/bin:$PATH"
count=0
ok() { count=$((count + 1)); printf 'ok %s - %s\n' "$count" "$1"; }
expect_failure() {
  if "$@" > "$tmp/output" 2>&1; then
    echo 'unexpected success (output intentionally withheld)' >&2; exit 1
  fi
}
fresh() {
  local dir="$tmp/repo-$count"
  mkdir -p "$dir/scripts" "$dir/tests"
  cd "$dir"
  git init -q
  cp "$source_root/scripts/check-env-index.sh" scripts/
  if [ -f "$source_root/scripts/prepare-env-tree.sh" ]; then cp "$source_root/scripts/prepare-env-tree.sh" scripts/; fi
  if [ -f "$source_root/justfile" ]; then cp "$source_root/justfile" .; fi
  cat > .gitignore <<'IGNORE'
*.env
.env.*
*.env.*
!.env.example
/env/dec/
/env/enc/*
!/env/enc/dev.env.enc
!/env/enc/prod.env.enc
IGNORE
  printf 'EXAMPLE=not-a-secret\n' > .env.example
  git add .gitignore .env.example
  : > "$CALL_LOG"
  rm -f -- "$MARKER"
}
valid_cipher() {
  mkdir -p env/enc
  # Deliberately only a structural fixture; not real authenticated ciphertext.
  printf '%s\n' \
    'EXAMPLE=ENC[AES256_GCM,data:ZmFrZQ==,iv:AA==,tag:AA==,type:str]' \
    'sops_mac=ENC[AES256_GCM,data:ZmFrZQ==,iv:AA==,tag:AA==,type:str]' \
    'sops_version=3.13.3' > env/enc/dev.env.enc
  git add env/enc/dev.env.enc
}

fresh
bash scripts/check-env-index.sh >/dev/null
ok 'empty ciphertext adoption is not mistaken for decryption proof'

for path in env/dec/.gitkeep env/dec/.env.example env/dec/arbitrary.txt nested/env/dec/.env.example private.env nested/.env.production env/enc/staging.env.enc env/enc/config.json.enc; do
  fresh
  mkdir -p -- "$(dirname -- "$path")"
  printf 'synthetic\n' > "$path"
  git add -f -- "$path"
  expect_failure bash scripts/check-env-index.sh
  ok 'forbidden staged path rejected, including placeholder/example bypasses'
done

fresh
valid_cipher
bash scripts/check-env-index.sh >/dev/null
ok 'canonical structural ciphertext accepted without decryption'

fresh
valid_cipher
cp env/enc/dev.env.enc "$tmp/valid"
printf 'EXAMPLE=STAGED_PLAINTEXT_MARKER\n' > env/enc/dev.env.enc
git add env/enc/dev.env.enc
cp "$tmp/valid" env/enc/dev.env.enc
expect_failure bash scripts/check-env-index.sh
! grep -q 'STAGED_PLAINTEXT_MARKER' "$tmp/output"
ok 'unsafe staged ciphertext cannot be hidden by clean working-tree bytes'

for extra in 'not-an-assignment' 'EXAMPLE=ENC[not-authenticated]' 'sops_password=PLAINTEXT_MARKER'; do
  fresh
  valid_cipher
  printf '%s\n' "$extra" >> env/enc/dev.env.enc
  git add env/enc/dev.env.enc
  expect_failure bash scripts/check-env-index.sh
  ! grep -q 'PLAINTEXT_MARKER' "$tmp/output"
  ok 'malformed, duplicate, or unknown metadata assignment rejected without values'
done

fresh
valid_cipher
rm env/enc/dev.env.enc
ln -s ../../.env.example env/enc/dev.env.enc
git add env/enc/dev.env.enc
expect_failure bash scripts/check-env-index.sh
ok 'staged ciphertext symlink rejected'

fresh
printf 'prefix\0AGE-SE%s-KEY-1-SYNTHETIC\n' 'CRET' > key.bin
git add key.bin
printf 'clean\n' > key.bin
expect_failure bash scripts/check-env-index.sh
! grep -q 'SYNTHETIC' "$tmp/output"
ok 'binary private-key marker in index rejected despite clean worktree'

fresh
name=$'nested/odd\nname.env'
mkdir -p nested
printf 'synthetic\n' > "$name"
git add -f -- "$name"
expect_failure bash scripts/check-env-index.sh
ok 'newline filename cannot split path enumeration'

fresh
valid_cipher
oid=$(git hash-object .env.example)
printf '0 0000000000000000000000000000000000000000\tconflict\n100644 %s 1\tconflict\n100644 %s 2\tconflict\n' "$oid" "$oid" | git update-index --index-info
expect_failure bash scripts/check-env-index.sh
ok 'unresolved index fails closed'

if [ -f "$source_root/scripts/prepare-env-tree.sh" ]; then
  for name in staging '../escape' 'dev; touch "$MARKER"' "dev'" 'dev prod' ''; do
    fresh
    expect_failure bash scripts/prepare-env-tree.sh "$name"
    [ ! -e env ] && [ ! -e "$MARKER" ]
    ok 'invalid profile rejected before creating managed paths'
  done
  fresh
  expect_failure bash scripts/prepare-env-tree.sh dev extra
  [ ! -e env ]
  ok 'extra profile arguments rejected'

  fresh
  bash scripts/prepare-env-tree.sh dev
  mode=$(stat -c '%a' env/dec 2>/dev/null || stat -f '%Lp' env/dec)
  [ "$mode" = 700 ]
  git check-ignore --no-index -q env/dec/.gitkeep
  ok 'fresh runtime directory is private and placeholders remain ignored'

  fresh
  mkdir -p env "$tmp/outside-$count"
  chmod 755 "$tmp/outside-$count"
  ln -s "$tmp/outside-$count" env/dec
  expect_failure bash scripts/prepare-env-tree.sh dev
  mode=$(stat -c '%a' "$tmp/outside-$count" 2>/dev/null || stat -f '%Lp' "$tmp/outside-$count")
  [ "$mode" = 755 ]
  ok 'directory symlink target is not chmod-ed'

  fresh
  bash scripts/prepare-env-tree.sh dev
  printf 'KEEP\n' > "$tmp/outside-file-$count"
  ln "$tmp/outside-file-$count" env/dec/dev.env
  expect_failure bash scripts/prepare-env-tree.sh dev
  [ "$(cat "$tmp/outside-file-$count")" = KEEP ]
  ok 'hardlinked plaintext refused without modifying outside target'

  fresh
  bash scripts/prepare-env-tree.sh dev
  printf 'KEEP\n' > env/dec/dev.env
  chmod 644 env/dec/dev.env
  expect_failure bash scripts/prepare-env-tree.sh dev
  ok 'over-readable plaintext refused'

  fresh
  printf 'KEEP\n' > .env
  expect_failure bash scripts/prepare-env-tree.sh dev
  [ "$(cat .env)" = KEEP ]
  ok 'unmanaged root dotenv preserved'

  fresh
  bash scripts/prepare-env-tree.sh dev
  ln -s env/dec/dev.env .env
  bash scripts/prepare-env-tree.sh dev
  ok 'exact managed relative dotenv link accepted'
fi

if [ "$with_just" -eq 1 ]; then
  for recipe in seed run test-env use edit encrypt diff verify-release-policy; do
    fresh
    expect_failure just "$recipe" 'dev; touch "$MARKER"'
    [ ! -e "$MARKER" ] && [ ! -s "$CALL_LOG" ] && [ ! -e env ]
    ok 'real Just rejects hostile profile before provider/helper execution'
  done
  fresh
  just seed dev >/dev/null
  expect_failure just seed dev
  grep -qx 'EXAMPLE=not-a-secret' env/dec/dev.env
  ok 'real Just seed never overwrites existing plaintext'

  fresh
  command="printf '%s' \"quoted value\"; touch \"\$MARKER\""
  just exec-env dev "$command" >/dev/null
  [ ! -e "$MARKER" ]
  python3 - "$CALL_LOG" "$command" <<'PY'
import pathlib, sys
args = pathlib.Path(sys.argv[1]).read_bytes().split(b'\0')[:-1]
assert args == [b'sops', b'exec-env', b'--input-type', b'dotenv', b'env/enc/dev.env.enc', sys.argv[2].encode()]
PY
  ok 'trusted command preserved as one SOPS argument, never run by outer shell'
  fresh
  expect_failure env TEST_SOPS_STATUS=23 just run dev
  [ ! -e env/dec/dev.env ]
  ok 'SOPS failure propagates without writing plaintext'
else
  printf 'NOTE: real Just parser/recipe tests not requested; run --with-just in the pinned Nix shell.\n'
fi
printf 'PASS: %s keyless boundary tests\n' "$count"
