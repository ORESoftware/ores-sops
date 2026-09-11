#!/usr/bin/env bats

recipient_for() {
  grep -o 'age1[a-z0-9]\{58\}' "$1" | head -1
}

sops_decrypt() {
  local key_file="$1" file="$2"
  SOPS_AGE_KEY_FILE="$key_file" \
    sops decrypt --input-type dotenv --output-type dotenv "$file" >/dev/null 2>&1
}

write_three_rules() {
  local stage_recipients="$1"
  cat > .sops.yaml <<EOF_SOPS
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc\$
    age:
      - $DEV_RECIPIENT
      - $RECOVERY_RECIPIENT
  - path_regex: ^env/enc/stage\.env\.enc\$
    age:
$stage_recipients
  - path_regex: ^env/enc/prod\.env\.enc\$
    age:
      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT
EOF_SOPS
}

setup() {
  export TESTDIR="$BATS_TEST_TMPDIR/stage"
  export DEV_KEY="$BATS_TEST_TMPDIR/stage-dev.age"
  export STAGE_KEY="$BATS_TEST_TMPDIR/stage-stage.age"
  export STAGE_NEW_KEY="$BATS_TEST_TMPDIR/stage-new.age"
  export PROD_KEY="$BATS_TEST_TMPDIR/stage-prod.age"
  export RECOVERY_KEY="$BATS_TEST_TMPDIR/stage-recovery.age"

  age-keygen -o "$DEV_KEY" 2>/dev/null
  age-keygen -o "$STAGE_KEY" 2>/dev/null
  age-keygen -o "$STAGE_NEW_KEY" 2>/dev/null
  age-keygen -o "$PROD_KEY" 2>/dev/null
  age-keygen -o "$RECOVERY_KEY" 2>/dev/null

  export DEV_RECIPIENT="$(recipient_for "$DEV_KEY")"
  export STAGE_RECIPIENT="$(recipient_for "$STAGE_KEY")"
  export STAGE_NEW_RECIPIENT="$(recipient_for "$STAGE_NEW_KEY")"
  export PROD_RECIPIENT="$(recipient_for "$PROD_KEY")"
  export RECOVERY_RECIPIENT="$(recipient_for "$RECOVERY_KEY")"

  mkdir -p "$TESTDIR/env/enc" "$TESTDIR/env/dec"
  chmod 700 "$TESTDIR/env/dec"
  cd "$TESTDIR"
  git init -q .
  git config user.email stage-test@example.invalid
  git config user.name stage-test
  git config commit.gpgsign false

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
!/env/enc/stage.env.enc
!/env/enc/prod.env.enc
EOF_IGNORE
  printf '/env/enc/*.env.enc text eol=lf\n' > .gitattributes

  write_three_rules "      - $STAGE_RECIPIENT
      - $RECOVERY_RECIPIENT"

  printf 'PILOT_ENV=dev\nPILOT_VALUE=dummy-development-only\n' > env/dec/dev.env
  SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops encrypt dev >/dev/null
  printf 'PILOT_ENV=stage\nPILOT_VALUE=dummy-staging-only\n' > env/dec/stage.env
  SOPS_AGE_KEY_FILE="$STAGE_KEY" ores-sops encrypt stage >/dev/null
  printf 'PILOT_ENV=prod\nPILOT_VALUE=dummy-production-only\n' > env/dec/prod.env
  SOPS_AGE_KEY_FILE="$PROD_KEY" ores-sops encrypt prod >/dev/null
  ores-sops lock >/dev/null
}

@test "dev stage and prod use independent identities while recovery can decrypt all" {
  sops_decrypt "$DEV_KEY" env/enc/dev.env.enc
  ! sops_decrypt "$DEV_KEY" env/enc/stage.env.enc
  ! sops_decrypt "$DEV_KEY" env/enc/prod.env.enc

  ! sops_decrypt "$STAGE_KEY" env/enc/dev.env.enc
  sops_decrypt "$STAGE_KEY" env/enc/stage.env.enc
  ! sops_decrypt "$STAGE_KEY" env/enc/prod.env.enc

  ! sops_decrypt "$PROD_KEY" env/enc/dev.env.enc
  ! sops_decrypt "$PROD_KEY" env/enc/stage.env.enc
  sops_decrypt "$PROD_KEY" env/enc/prod.env.enc

  sops_decrypt "$RECOVERY_KEY" env/enc/dev.env.enc
  sops_decrypt "$RECOVERY_KEY" env/enc/stage.env.enc
  sops_decrypt "$RECOVERY_KEY" env/enc/prod.env.enc
}

@test "strict three-environment access audit checks all ciphertext recipient metadata" {
  run ores-sops-access-audit check \
    --require-stage \
    --require-stage-exclusive \
    --require-prod-exclusive \
    --require-ciphertext

  [ "$status" -eq 0 ]
  [[ "$output" == *"dev=2, stage=2, prod=2"* ]]
  [[ "$output" == *"dev-only=1"* ]]
  [[ "$output" == *"stage-not-prod=1"* ]]
  [[ "$output" == *"prod-only=1"* ]]
  [[ "$output" == *"checked for 3 file(s)"* ]]
  [[ "$output" != *"$DEV_RECIPIENT"* ]]
  [[ "$output" != *"$STAGE_RECIPIENT"* ]]
  [[ "$output" != *"$PROD_RECIPIENT"* ]]
}

@test "stage activation writes only stage plaintext and uses a managed relative symlink" {
  SOPS_AGE_KEY_FILE="$STAGE_KEY" ores-sops use stage

  [ -L .env ]
  [ "$(readlink .env)" = "env/dec/stage.env" ]
  [ -f env/dec/stage.env ]
  [ ! -e env/dec/dev.env ]
  [ ! -e env/dec/prod.env ]
  grep -q '^PILOT_ENV=stage$' env/dec/stage.env
  [ "$(stat -c '%a' env/dec/stage.env 2>/dev/null || stat -f '%Lp' env/dec/stage.env)" = 600 ]

  run ores-sops status
  [ "$status" -eq 0 ]
  [[ "$output" != *"dummy-staging-only"* ]]
}

@test "dev-only identity cannot activate stage or production" {
  run env SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops use stage
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not decrypt 'stage'"* ]]
  [ ! -e env/dec/stage.env ]
  [ ! -e .env ]

  run env SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops use prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not decrypt 'prod'"* ]]
  [ ! -e env/dec/prod.env ]
  [ ! -e .env ]
}

@test "sync-keys changes only stage access and preserves dev and prod ciphertext" {
  dev_before="$(sha256sum env/enc/dev.env.enc | awk '{print $1}')"
  prod_before="$(sha256sum env/enc/prod.env.enc | awk '{print $1}')"

  write_three_rules "      - $STAGE_RECIPIENT
      - $STAGE_NEW_RECIPIENT
      - $RECOVERY_RECIPIENT"

  run ores-sops-access-audit check --require-stage --require-ciphertext
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage ciphertext recipients differ from .sops.yaml"* ]]

  SOPS_AGE_KEY_FILE="$STAGE_KEY" ores-sops sync-keys stage >/dev/null

  [ "$(sha256sum env/enc/dev.env.enc | awk '{print $1}')" = "$dev_before" ]
  [ "$(sha256sum env/enc/prod.env.enc | awk '{print $1}')" = "$prod_before" ]
  sops_decrypt "$STAGE_NEW_KEY" env/enc/stage.env.enc
  ! sops_decrypt "$STAGE_NEW_KEY" env/enc/dev.env.enc
  ! sops_decrypt "$STAGE_NEW_KEY" env/enc/prod.env.enc

  run ores-sops-access-audit check \
    --require-stage \
    --require-stage-exclusive \
    --require-prod-exclusive \
    --require-ciphertext
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked for 3 file(s)"* ]]
}

@test "verify accepts the exact optional stage contract and rejects aliases" {
  git add .sops.yaml .gitignore .gitattributes \
    env/enc/dev.env.enc env/enc/stage.env.enc env/enc/prod.env.enc

  run ores-sops verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"stage=enabled"* ]]

  printf 'DUMMY=ENC[fake]\nsops_mac=ENC[fake]\n' > env/enc/staging.env.enc
  git add -f env/enc/staging.env.enc
  run ores-sops precommit
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected tracked ciphertext path"* ]]
}

@test "stage ciphertext without the exact stage rule fails closed" {
  cat > .sops.yaml <<EOF_SOPS
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc\$
    age:
      - $DEV_RECIPIENT
      - $RECOVERY_RECIPIENT
  - path_regex: ^env/enc/prod\.env\.enc\$
    age:
      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT
EOF_SOPS

  run ores-sops verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage material exists without the exact stage SOPS creation rule"* ]]

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage ciphertext exists without the exact stage creation rule"* ]]
}

@test "lock removes stage plaintext and interrupted stage temp state" {
  SOPS_AGE_KEY_FILE="$STAGE_KEY" ores-sops use stage >/dev/null
  printf 'SECRET=temp\n' > env/dec/.stage.env.tmp.stale
  printf 'SECRET=diff\n' > env/dec/.stage.diff-base.stale
  printf 'SECRET=stamp\n' > env/dec/.stage.stamp.stale

  ores-sops lock

  [ ! -e .env ]
  [ ! -e env/dec/stage.env ]
  [ ! -e env/dec/.stage.env.tmp.stale ]
  [ ! -e env/dec/.stage.diff-base.stale ]
  [ ! -e env/dec/.stage.stamp.stale ]
}

@test "scoped init makes the local identity development-only and recovery spans all three" {
  fresh="$BATS_TEST_TMPDIR/scoped-stage-init"
  mkdir -p "$fresh"
  cd "$fresh"
  git init -q .

  SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops init \
    --with-stage \
    --stage-recipient "$STAGE_RECIPIENT" \
    --prod-recipient "$PROD_RECIPIENT" \
    --recovery-recipient "$RECOVERY_RECIPIENT"

  [ "$(grep -c -- "- $DEV_RECIPIENT" .sops.yaml)" = 1 ]
  [ "$(grep -c -- "- $STAGE_RECIPIENT" .sops.yaml)" = 1 ]
  [ "$(grep -c -- "- $PROD_RECIPIENT" .sops.yaml)" = 1 ]
  [ "$(grep -c -- "- $RECOVERY_RECIPIENT" .sops.yaml)" = 3 ]
  grep -Fq 'path_regex: ^env/enc/stage\.env\.enc$' .sops.yaml
  ! git check-ignore --no-index -q env/enc/stage.env.enc
  git check-ignore --no-index -q env/dec/stage.env

  run ores-sops-access-audit check \
    --require-stage \
    --require-stage-exclusive \
    --require-prod-exclusive \
    --policy-only
  [ "$status" -eq 0 ]
}
