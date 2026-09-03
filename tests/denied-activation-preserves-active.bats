#!/usr/bin/env bats

# Salvaged as a focused invariant from superseded PR #17. The shipped v0.4
# suite already proves denied decryption from a locked state; this additionally
# proves that a denied higher-environment activation cannot disturb an existing
# complete dev plaintext or the managed root symlink.

recipient_for() {
  grep -o 'age1[a-z0-9]\{58\}' "$1" | head -1
}

setup() {
  export TESTDIR="$BATS_TEST_TMPDIR/denied-activation-preserves-active"
  export DEV_KEY="$BATS_TEST_TMPDIR/preserve-dev.age"
  export STAGE_KEY="$BATS_TEST_TMPDIR/preserve-stage.age"
  export PROD_KEY="$BATS_TEST_TMPDIR/preserve-prod.age"

  age-keygen -o "$DEV_KEY" 2>/dev/null
  age-keygen -o "$STAGE_KEY" 2>/dev/null
  age-keygen -o "$PROD_KEY" 2>/dev/null

  DEV_RECIPIENT="$(recipient_for "$DEV_KEY")"
  STAGE_RECIPIENT="$(recipient_for "$STAGE_KEY")"
  PROD_RECIPIENT="$(recipient_for "$PROD_KEY")"

  mkdir -p "$TESTDIR/env/enc" "$TESTDIR/env/dec"
  chmod 700 "$TESTDIR/env/dec"
  cd "$TESTDIR"
  git init -q .
  git config user.email preserve-test@example.invalid
  git config user.name preserve-test
  git config commit.gpgsign false

  cat >.sops.yaml <<EOF_SOPS
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc\$
    age:
      - $DEV_RECIPIENT
  - path_regex: ^env/enc/stage\.env\.enc\$
    age:
      - $STAGE_RECIPIENT
  - path_regex: ^env/enc/prod\.env\.enc\$
    age:
      - $PROD_RECIPIENT
EOF_SOPS

  cat >.gitignore <<'EOF_IGNORE'
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
  printf '/env/enc/*.env.enc text eol=lf\n' >.gitattributes

  printf 'PILOT_ENV=dev\nPILOT_VALUE=dummy-development-only\n' >env/dec/dev.env
  SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops encrypt dev >/dev/null
  printf 'PILOT_ENV=stage\nPILOT_VALUE=dummy-stage-only\n' >env/dec/stage.env
  SOPS_AGE_KEY_FILE="$STAGE_KEY" ores-sops encrypt stage >/dev/null
  printf 'PILOT_ENV=prod\nPILOT_VALUE=dummy-production-only\n' >env/dec/prod.env
  SOPS_AGE_KEY_FILE="$PROD_KEY" ores-sops encrypt prod >/dev/null
  ores-sops lock >/dev/null
}

@test "denied stage and prod activation preserve active dev plaintext and symlink" {
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
