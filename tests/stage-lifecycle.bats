#!/usr/bin/env bats

recipient_for() {
  grep -o 'age1[a-z0-9]\{58\}' "$1" | head -1
}

sops_decrypt() {
  local key_file="$1" file="$2"
  SOPS_AGE_KEY_FILE="$key_file" sops decrypt --input-type dotenv --output-type dotenv "$file" >/dev/null 2>&1
}

write_rules() {
  cat > .sops.yaml <<EOF_SOPS
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc\$
    age:
      - $DEV_RECIPIENT
      - $RECOVERY_RECIPIENT
  - path_regex: ^env/enc/stage\.env\.enc\$
    age:
      - $STAGE_RECIPIENT
      - $RECOVERY_RECIPIENT
  - path_regex: ^env/enc/prod\.env\.enc\$
    age:
      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT
EOF_SOPS
}

setup() {
  export TESTDIR="$BATS_TEST_TMPDIR/stage-lifecycle"
  export DEV_KEY="$BATS_TEST_TMPDIR/dev.age"
  export STAGE_KEY="$BATS_TEST_TMPDIR/stage.age"
  export STAGE_NEW_KEY="$BATS_TEST_TMPDIR/stage-new.age"
  export PROD_KEY="$BATS_TEST_TMPDIR/prod.age"
  export RECOVERY_KEY="$BATS_TEST_TMPDIR/recovery.age"

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
  git config user.email stage-lifecycle@example.invalid
  git config user.name stage-lifecycle-test
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
  write_rules

  printf 'PILOT_ENV=dev\nPILOT_VALUE=dummy-development-only\n' > env/dec/dev.env
  SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops encrypt dev >/dev/null
  printf 'PILOT_ENV=stage\nPILOT_VALUE=dummy-stage-only\n' > env/dec/stage.env
  SOPS_AGE_KEY_FILE="$STAGE_KEY" ores-sops encrypt stage >/dev/null
  printf 'PILOT_ENV=prod\nPILOT_VALUE=dummy-production-only\n' > env/dec/prod.env
  SOPS_AGE_KEY_FILE="$PROD_KEY" ores-sops encrypt prod >/dev/null
  SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops lock >/dev/null

  git add .sops.yaml .gitignore .gitattributes env/enc/dev.env.enc env/enc/stage.env.enc env/enc/prod.env.enc
}

@test "dev-only identity cannot decrypt stage or prod" {
  sops_decrypt "$DEV_KEY" env/enc/dev.env.enc
  ! sops_decrypt "$DEV_KEY" env/enc/stage.env.enc
  ! sops_decrypt "$DEV_KEY" env/enc/prod.env.enc
}

@test "stage-only identity cannot decrypt dev or prod" {
  ! sops_decrypt "$STAGE_KEY" env/enc/dev.env.enc
  sops_decrypt "$STAGE_KEY" env/enc/stage.env.enc
  ! sops_decrypt "$STAGE_KEY" env/enc/prod.env.enc
}

@test "prod-only identity cannot decrypt dev or stage" {
  ! sops_decrypt "$PROD_KEY" env/enc/dev.env.enc
  ! sops_decrypt "$PROD_KEY" env/enc/stage.env.enc
  sops_decrypt "$PROD_KEY" env/enc/prod.env.enc
}

@test "explicit recovery identity decrypts all configured environments" {
  sops_decrypt "$RECOVERY_KEY" env/enc/dev.env.enc
  sops_decrypt "$RECOVERY_KEY" env/enc/stage.env.enc
  sops_decrypt "$RECOVERY_KEY" env/enc/prod.env.enc
}


@test "unauthorized stage and prod activation leave dev plaintext and symlink untouched" {
  SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops use dev >/dev/null
  cp env/dec/dev.env "$BATS_TEST_TMPDIR/dev-before.env"
  before_target="$(readlink .env)"

  run env SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops use stage
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not decrypt 'stage'"* ]]
  [ ! -e env/dec/stage.env ]
  [ "$(readlink .env)" = "$before_target" ]
  cmp "$BATS_TEST_TMPDIR/dev-before.env" env/dec/dev.env

  run env SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops use prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not decrypt 'prod'"* ]]
  [ ! -e env/dec/prod.env ]
  [ "$(readlink .env)" = "$before_target" ]
  cmp "$BATS_TEST_TMPDIR/dev-before.env" env/dec/dev.env
}

@test "stage activation is atomic and uses the managed relative symlink" {
  SOPS_AGE_KEY_FILE="$STAGE_KEY" ores-sops use stage
  [ -L .env ]
  [ "$(readlink .env)" = "env/dec/stage.env" ]
  grep -q '^PILOT_ENV=stage$' env/dec/stage.env
  [ "$(stat -c '%a' env/dec/stage.env 2>/dev/null || stat -f '%Lp' env/dec/stage.env)" = 600 ]
}

@test "status and lock include stage without exposing values" {
  SOPS_AGE_KEY_FILE="$STAGE_KEY" ores-sops use stage >/dev/null
  run ores-sops status
  [ "$status" -eq 0 ]
  [[ "$output" == *"stage"* ]]
  [[ "$output" != *"dummy-stage-only"* ]]

  ores-sops lock
  [ ! -e .env ]
  [ ! -e env/dec/stage.env ]
}

@test "verify accepts exact optional stage and rejects arbitrary env names" {
  run ores-sops verify
  [ "$status" -eq 0 ]

  run ores-sops use qa
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported environment 'qa'"* ]]
}

@test "sync-keys changes only stage access" {
  cat > .sops.yaml <<EOF_SOPS
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc\$
    age:
      - $DEV_RECIPIENT
      - $RECOVERY_RECIPIENT
  - path_regex: ^env/enc/stage\.env\.enc\$
    age:
      - $STAGE_RECIPIENT
      - $STAGE_NEW_RECIPIENT
      - $RECOVERY_RECIPIENT
  - path_regex: ^env/enc/prod\.env\.enc\$
    age:
      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT
EOF_SOPS

  SOPS_AGE_KEY_FILE="$STAGE_KEY" ores-sops sync-keys stage >/dev/null

  sops_decrypt "$STAGE_NEW_KEY" env/enc/stage.env.enc
  ! sops_decrypt "$STAGE_NEW_KEY" env/enc/dev.env.enc
  ! sops_decrypt "$STAGE_NEW_KEY" env/enc/prod.env.enc
  sops_decrypt "$DEV_KEY" env/enc/dev.env.enc
  sops_decrypt "$PROD_KEY" env/enc/prod.env.enc
}

@test "access audit checks all real ciphertext metadata" {
  run ores-sops-access-audit check --require-ciphertext
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked for 3 file(s)"* ]]
  [[ "$output" == *"dev-only=1"* ]]
  [[ "$output" == *"stage-not-prod=1"* ]]
}

@test "init with stage and scoped recipients emits exact rules and allowlist" {
  fresh="$BATS_TEST_TMPDIR/stage-init"
  mkdir -p "$fresh"
  cd "$fresh"
  git init -q .
  export SOPS_AGE_KEY_FILE="$DEV_KEY"

  ores-sops init --with-stage \
    --local-scope dev \
    --stage-recipient "$STAGE_RECIPIENT" \
    --prod-recipient "$PROD_RECIPIENT" \
    --recovery-recipient "$RECOVERY_RECIPIENT"

  grep -Fq 'path_regex: ^env/enc/stage\.env\.enc$' .sops.yaml
  grep -Fxq '!/env/enc/stage.env.enc' .gitignore
  run ores-sops-access-audit check --policy-only
  [ "$status" -eq 0 ]
}
