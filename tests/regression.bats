#!/usr/bin/env bats

setup() {
  export TESTDIR="$BATS_TEST_TMPDIR/repo"
  export SOPS_AGE_KEY_FILE="$BATS_TEST_TMPDIR/age.txt"
  age-keygen -o "$SOPS_AGE_KEY_FILE" 2>/dev/null
  RECIPIENT="$(grep -o 'age1[a-z0-9]\{58\}' "$SOPS_AGE_KEY_FILE" | head -1)"

  mkdir -p "$TESTDIR"
  cd "$TESTDIR"
  git init -q .
  git config user.email t@example.com
  git config user.name t
  git config commit.gpgsign false

  mkdir -p env/enc env/dec
  chmod 700 env/dec
  cat > .sops.yaml <<EOF_SOPS
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc\$
    age:
      - $RECIPIENT
  - path_regex: ^env/enc/prod\.env\.enc\$
    age:
      - $RECIPIENT
EOF_SOPS

  cat > .gitignore <<'EOF_IGNORE'
*.env
*/*.env
*/**/*.env
.env.*
*.env.*
!.env.example
/env/dec/
/env/enc/*
!/env/enc/dev.env.enc
!/env/enc/prod.env.enc
EOF_IGNORE
  printf '/env/enc/*.env.enc text eol=lf\n' > .gitattributes

  printf 'ALPHA=one\nBRAVO=dev-original\n' > env/dec/dev.env
  ores-sops encrypt dev >/dev/null
  printf 'ALPHA=one\nBRAVO=prod-original\n' > env/dec/prod.env
  ores-sops encrypt prod >/dev/null
  ores-sops lock >/dev/null
  git add .sops.yaml .gitignore .gitattributes env/enc/dev.env.enc env/enc/prod.env.enc
  git commit -qm baseline
}

@test "help and version stay side-effect free" {
  rm -rf env/dec
  run ores-sops --version
  [ "$status" -eq 0 ]
  [[ "$output" == ores-sops\ * ]]
  [ ! -e env/dec ]

  run ores-sops help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ensure-dec"* ]]
  [ ! -e env/dec ]
}

@test "unknown commands fail without creating env/dec" {
  rm -rf env/dec
  run ores-sops frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command 'frobnicate'"* ]]
  [ ! -e env/dec ]
}

@test "ensure-dec refuses a symlinked env directory" {
  outside="$BATS_TEST_TMPDIR/outside-env"
  mkdir -p "$outside"
  rm -rf env
  ln -s "$outside" env
  run ores-sops ensure-dec
  [ "$status" -ne 0 ]
  [[ "$output" == *"managed path must not be a symlink"* ]]
  [ ! -e "$outside/dec" ]
}

@test "ensure-dec refuses a non-directory env/dec" {
  rm -rf env/dec
  printf 'not-a-dir\n' > env/dec
  run ores-sops ensure-dec
  [ "$status" -ne 0 ]
  [[ "$output" == *"managed path must be a directory"* ]]
  [ -f env/dec ]
}

@test "use --force discards local plaintext edits" {
  ores-sops use dev
  printf 'ALPHA=one\nBRAVO=discard-me\n' > env/dec/dev.env
  ores-sops use --force dev
  grep -q '^BRAVO=dev-original$' env/dec/dev.env
  [[ "$(readlink .env)" == "env/dec/dev.env" ]]
}

@test "encrypt refuses to replace ciphertext with an empty plaintext" {
  ores-sops use dev
  printf '# comments only\n' > env/dec/dev.env
  before="$(sha256sum env/enc/dev.env.enc | awk '{print $1}')"
  run ores-sops encrypt dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to replace existing ciphertext"* ]]
  [ "$(sha256sum env/enc/dev.env.enc | awk '{print $1}')" = "$before" ]
}

@test "encrypt --allow-empty can replace ciphertext after explicit confirmation" {
  ores-sops use dev
  printf '# empty on purpose\n' > env/dec/dev.env
  ores-sops encrypt --allow-empty dev
  [ -f env/enc/dev.env.enc ]
  grep -q '^sops_mac=ENC\[' env/enc/dev.env.enc
}

@test "malformed dotenv is rejected before encryption" {
  ores-sops use dev
  printf 'ALPHA=one\nthis is not dotenv\n' > env/dec/dev.env
  run ores-sops encrypt dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed non-comment line"* ]]
}

@test "encrypt leaves status current instead of immediately STALE" {
  ores-sops use dev
  printf 'ALPHA=one\nBRAVO=rotated\n' > env/dec/dev.env
  ores-sops encrypt dev
  run ores-sops status
  [ "$status" -eq 0 ]
  [[ "$output" != *"STALE"* ]]
  [[ "$output" == *"dev"* ]]
}

@test "switching environments updates the relative root symlink" {
  ores-sops use dev
  ores-sops use prod
  [ "$(readlink .env)" = "env/dec/prod.env" ]
  grep -q '^BRAVO=prod-original$' env/dec/prod.env
}

@test "refresh updates active plaintext after ciphertext changes" {
  ores-sops use dev
  printf 'ALPHA=one\nBRAVO=refreshed\n' > "$BATS_TEST_TMPDIR/new.env"
  sops encrypt --input-type dotenv --output-type dotenv \
    --filename-override env/enc/dev.env.enc "$BATS_TEST_TMPDIR/new.env" \
    > env/enc/dev.env.enc
  run ores-sops refresh
  [ "$status" -eq 0 ]
  grep -q '^BRAVO=refreshed$' env/dec/dev.env
  [[ "$output" == *"refreshed env/dec/dev.env"* ]]
}

@test "refresh does not overwrite local edits" {
  ores-sops use dev
  printf 'ALPHA=one\nBRAVO=keep-local\n' > env/dec/dev.env
  run ores-sops refresh
  [ "$status" -eq 0 ]
  grep -q '^BRAVO=keep-local$' env/dec/dev.env
  [[ "$output" == *"local edits"* ]]
}

@test "lock refuses to remove an unmanaged root .env file" {
  printf 'KEEP=local\n' > .env
  run ores-sops lock
  [ "$status" -ne 0 ]
  [[ "$output" == *"unmanaged root .env"* ]]
  grep -q '^KEEP=local$' .env
}

@test "use fails on missing ciphertext without creating plaintext" {
  rm -f env/enc/dev.env.enc
  run ores-sops use dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing env/enc/dev.env.enc"* ]]
  [ ! -f env/dec/dev.env ]
}

@test "authorized decrypt verify succeeds without printing values" {
  run env ORES_SOPS_VERIFY_DECRYPT=1 ores-sops verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"policy verification passed"* ]]
  [[ "$output" != *"dev-original"* ]]
  [[ "$output" != *"prod-original"* ]]
}

@test "status never prints ENC payloads" {
  run ores-sops status
  [ "$status" -eq 0 ]
  [[ "$output" != *"ENC["* ]]
  [[ "$output" == *"encrypted only"* ]]
}
