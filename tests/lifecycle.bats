#!/usr/bin/env bats

recipient_for() {
  grep -o 'age1[a-z0-9]\{58\}' "$1" | head -1
}

write_rules() {
  local dev_recipients="$1"
  cat > .sops.yaml <<EOF_SOPS
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc\$
    age:
$dev_recipients
  - path_regex: ^env/enc/prod\.env\.enc\$
    age:
      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT
EOF_SOPS
}

sops_decrypt() {
  local key_file="$1" file="$2"
  SOPS_AGE_KEY_FILE="$key_file" sops decrypt --input-type dotenv --output-type dotenv "$file" >/dev/null 2>&1
}

setup() {
  export TESTDIR="$BATS_TEST_TMPDIR/lifecycle"
  export DEV_OLD_KEY="$BATS_TEST_TMPDIR/dev-old.age"
  export DEV_NEW_KEY="$BATS_TEST_TMPDIR/dev-new.age"
  export PROD_KEY="$BATS_TEST_TMPDIR/prod.age"
  export RECOVERY_KEY="$BATS_TEST_TMPDIR/recovery.age"

  age-keygen -o "$DEV_OLD_KEY" 2>/dev/null
  age-keygen -o "$DEV_NEW_KEY" 2>/dev/null
  age-keygen -o "$PROD_KEY" 2>/dev/null
  age-keygen -o "$RECOVERY_KEY" 2>/dev/null

  export DEV_OLD_RECIPIENT="$(recipient_for "$DEV_OLD_KEY")"
  export DEV_NEW_RECIPIENT="$(recipient_for "$DEV_NEW_KEY")"
  export PROD_RECIPIENT="$(recipient_for "$PROD_KEY")"
  export RECOVERY_RECIPIENT="$(recipient_for "$RECOVERY_KEY")"

  mkdir -p "$TESTDIR/env/enc" "$TESTDIR/env/dec"
  chmod 700 "$TESTDIR/env/dec"
  cd "$TESTDIR"
  git init -q .
  git config user.email lifecycle@example.invalid
  git config user.name lifecycle-test
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
!/env/enc/prod.env.enc
EOF_IGNORE
  printf '/env/enc/*.env.enc text eol=lf\n' > .gitattributes

  write_rules "      - $DEV_OLD_RECIPIENT
      - $RECOVERY_RECIPIENT"

  printf 'PILOT_ENV=dev\nPILOT_VALUE=dummy-development-only\n' > env/dec/dev.env
  SOPS_AGE_KEY_FILE="$DEV_OLD_KEY" ores-sops encrypt dev >/dev/null
  printf 'PILOT_ENV=prod\nPILOT_VALUE=dummy-production-only\n' > env/dec/prod.env
  SOPS_AGE_KEY_FILE="$PROD_KEY" ores-sops encrypt prod >/dev/null
  SOPS_AGE_KEY_FILE="$DEV_OLD_KEY" ores-sops lock >/dev/null
}

@test "dev and prod identities are separated while recovery can decrypt both" {
  sops_decrypt "$DEV_OLD_KEY" env/enc/dev.env.enc
  ! sops_decrypt "$DEV_OLD_KEY" env/enc/prod.env.enc
  sops_decrypt "$PROD_KEY" env/enc/prod.env.enc
  ! sops_decrypt "$PROD_KEY" env/enc/dev.env.enc
  sops_decrypt "$RECOVERY_KEY" env/enc/dev.env.enc
  sops_decrypt "$RECOVERY_KEY" env/enc/prod.env.enc
}

@test "adding a dev recipient with updatekeys grants new access without changing prod access" {
  write_rules "      - $DEV_OLD_RECIPIENT
      - $DEV_NEW_RECIPIENT
      - $RECOVERY_RECIPIENT"

  SOPS_AGE_KEY_FILE="$DEV_OLD_KEY" \
    sops updatekeys -y --input-type dotenv env/enc/dev.env.enc >/dev/null 2>&1

  sops_decrypt "$DEV_NEW_KEY" env/enc/dev.env.enc
  ! sops_decrypt "$DEV_NEW_KEY" env/enc/prod.env.enc
  sops_decrypt "$PROD_KEY" env/enc/prod.env.enc
}

@test "offboarding removes the old dev identity before and after data-key rotation" {
  write_rules "      - $DEV_OLD_RECIPIENT
      - $DEV_NEW_RECIPIENT
      - $RECOVERY_RECIPIENT"
  SOPS_AGE_KEY_FILE="$DEV_OLD_KEY" \
    sops updatekeys -y --input-type dotenv env/enc/dev.env.enc >/dev/null 2>&1

  write_rules "      - $DEV_NEW_RECIPIENT
      - $RECOVERY_RECIPIENT"
  SOPS_AGE_KEY_FILE="$DEV_OLD_KEY" \
    sops updatekeys -y --input-type dotenv env/enc/dev.env.enc >/dev/null 2>&1

  # updatekeys is the access-removal boundary: prove the old identity is gone
  # and both retained identities work before rotating the per-file data key.
  ! sops_decrypt "$DEV_OLD_KEY" env/enc/dev.env.enc
  sops_decrypt "$DEV_NEW_KEY" env/enc/dev.env.enc
  sops_decrypt "$RECOVERY_KEY" env/enc/dev.env.enc

  before="$(sha256sum env/enc/dev.env.enc | awk '{print $1}')"
  SOPS_AGE_KEY_FILE="$DEV_NEW_KEY" \
    sops --rotate --in-place --input-type dotenv --output-type dotenv \
      env/enc/dev.env.enc >/dev/null 2>&1
  after="$(sha256sum env/enc/dev.env.enc | awk '{print $1}')"

  [ "$before" != "$after" ]
  grep -q '^sops_mac=ENC\[' env/enc/dev.env.enc
  ! sops_decrypt "$DEV_OLD_KEY" env/enc/dev.env.enc
  sops_decrypt "$DEV_NEW_KEY" env/enc/dev.env.enc
  sops_decrypt "$RECOVERY_KEY" env/enc/dev.env.enc
}

@test "generated private identities never enter the repository index" {
  git add .sops.yaml .gitignore .gitattributes env/enc/dev.env.enc env/enc/prod.env.enc
  run ores-sops verify
  [ "$status" -eq 0 ]

  while IFS= read -r tracked; do
    case "$tracked" in
      *.age|*keys.txt) false ;;
    esac
  done < <(git ls-files)
}
