#!/usr/bin/env bats

make_recipient() {
  local character="$1"
  printf 'age1'
  printf '%058d' 0 | tr '0' "$character"
}

write_policy() {
  local dev_block="$1" prod_block="$2"
  cat > .sops.yaml <<EOF_SOPS
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc\$
    age:
$dev_block
  - path_regex: ^env/enc/prod\.env\.enc\$
    age:
$prod_block
EOF_SOPS
}

write_ciphertext() {
  local environment="$1" recipient index=0
  shift
  mkdir -p env/enc
  {
    printf 'DUMMY=ENC[fake]\n'
    for recipient in "$@"; do
      printf 'sops_age__list_%s__map_recipient=%s\n' "$index" "$recipient"
      index=$((index + 1))
    done
    printf 'sops_mac=ENC[fake]\n'
  } >"env/enc/$environment.env.enc"
}

setup() {
  export TESTDIR="$BATS_TEST_TMPDIR/access-audit"
  export DEV_RECIPIENT="$(make_recipient d)"
  export PROD_RECIPIENT="$(make_recipient p)"
  export RECOVERY_RECIPIENT="$(make_recipient r)"
  export SECOND_RECOVERY_RECIPIENT="$(make_recipient s)"

  mkdir -p "$TESTDIR"
  cd "$TESTDIR"

  write_policy "      - $DEV_RECIPIENT
      - $RECOVERY_RECIPIENT" "      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT"
}

@test "check accepts distinct dev and prod recipients with shared recovery" {
  run ores-sops-access-audit check
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed (dev=2, prod=2, shared=1, dev-only=1, prod-only=1)"* ]]
  [[ "$output" == *"checked for 0 file(s)"* ]]
  [[ "$output" != *"$DEV_RECIPIENT"* ]]
  [[ "$output" != *"$PROD_RECIPIENT"* ]]
  [[ "$output" != *"$RECOVERY_RECIPIENT"* ]]
}

@test "show emits only the desired public recipient matrix" {
  run ores-sops-access-audit show
  [ "$status" -eq 0 ]
  [[ "$output" == *$'environment\tpublic_age_recipient'* ]]
  [[ "$output" == *$'dev\t'"$DEV_RECIPIENT"* ]]
  [[ "$output" == *$'prod\t'"$PROD_RECIPIENT"* ]]
  [[ "$output" == *$'dev\t'"$RECOVERY_RECIPIENT"* ]]
  [[ "$output" == *$'prod\t'"$RECOVERY_RECIPIENT"* ]]
}

@test "matching ciphertext recipient metadata passes regardless of ordering" {
  write_ciphertext dev "$RECOVERY_RECIPIENT" "$DEV_RECIPIENT"
  write_ciphertext prod "$PROD_RECIPIENT" "$RECOVERY_RECIPIENT"

  run ores-sops-access-audit check --require-ciphertext
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked for 2 file(s)"* ]]
  [[ "$output" != *"$DEV_RECIPIENT"* ]]
  [[ "$output" != *"$PROD_RECIPIENT"* ]]
}

@test "stale ciphertext recipient metadata fails until updatekeys is run" {
  write_ciphertext dev "$DEV_RECIPIENT" "$RECOVERY_RECIPIENT"
  write_ciphertext prod "$DEV_RECIPIENT" "$RECOVERY_RECIPIENT"

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"prod ciphertext recipients differ from .sops.yaml"* ]]
  [[ "$output" == *"sops updatekeys"* ]]
  [[ "$output" != *"$DEV_RECIPIENT"* ]]
  [[ "$output" != *"$PROD_RECIPIENT"* ]]
}

@test "policy-only mode explicitly skips stale ciphertext metadata" {
  write_ciphertext dev "$DEV_RECIPIENT" "$RECOVERY_RECIPIENT"
  write_ciphertext prod "$DEV_RECIPIENT" "$RECOVERY_RECIPIENT"

  run ores-sops-access-audit check --policy-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"ciphertext sync explicitly skipped"* ]]
}

@test "require-ciphertext fails when the tracked access state is absent" {
  run ores-sops-access-audit check --require-ciphertext
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required ciphertext: env/enc/dev.env.enc"* ]]
}

@test "symlinked ciphertext metadata source is rejected" {
  mkdir -p env/enc
  write_ciphertext prod "$PROD_RECIPIENT" "$RECOVERY_RECIPIENT"
  printf 'sops_age__list_0__map_recipient=%s\n' "$DEV_RECIPIENT" >outside.enc
  ln -s ../../outside.enc env/enc/dev.env.enc

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev ciphertext must not be a symlink"* ]]
}

@test "malformed ciphertext metadata keys fail closed" {
  mkdir -p env/enc
  cat >env/enc/dev.env.enc <<EOF_CIPHERTEXT
sops_age__list_notanindex__map_recipient=$DEV_RECIPIENT
sops_age__list_1__map_recipient=$RECOVERY_RECIPIENT
EOF_CIPHERTEXT

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed SOPS age recipient metadata key"* ]]
}

@test "identical recipient sets fail closed" {
  write_policy "      - $DEV_RECIPIENT
      - $RECOVERY_RECIPIENT" "      - $DEV_RECIPIENT
      - $RECOVERY_RECIPIENT"

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"every dev recipient can decrypt prod"* ]]
}

@test "dev access contained in prod fails because every dev key would unlock prod" {
  write_policy "      - $DEV_RECIPIENT
      - $RECOVERY_RECIPIENT" "      - $DEV_RECIPIENT
      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT"

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"every dev recipient can decrypt prod"* ]]
}

@test "prod recipients may also retain dev access while dev-only users stay isolated" {
  write_policy "      - $DEV_RECIPIENT
      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT" "      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT"

  run ores-sops-access-audit check
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev-only=1, prod-only=0"* ]]
}

@test "strict policy can require a distinct production-only identity" {
  write_policy "      - $DEV_RECIPIENT
      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT" "      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT"

  run ores-sops-access-audit check --require-prod-exclusive
  [ "$status" -ne 0 ]
  [[ "$output" == *"--require-prod-exclusive was requested"* ]]
}

@test "one recipient per environment needs an explicit bootstrap override" {
  write_policy "      - $DEV_RECIPIENT" "      - $PROD_RECIPIENT"

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"require at least 2"* ]]

  run ores-sops-access-audit check --min-recipients 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev=1, prod=1"* ]]
}

@test "mutually exclusive ciphertext modes are rejected" {
  run ores-sops-access-audit check --policy-only --require-ciphertext
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "duplicate recipients are rejected instead of silently normalized" {
  write_policy "      - $DEV_RECIPIENT
      - $DEV_RECIPIENT" "      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT"

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate public age recipient in the dev rule"* ]]
}

@test "malformed public recipients are rejected without echoing them" {
  malformed="age1not-a-real-recipient"
  write_policy "      - $malformed
      - $RECOVERY_RECIPIENT" "      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT"

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed public age recipient"* ]]
  [[ "$output" != *"$malformed"* ]]
}

@test "noncanonical env enc creation rules fail closed" {
  cat >> .sops.yaml <<EOF_SOPS
  - path_regex: ^env/enc/.*\.env\.enc\$
    age:
      - $SECOND_RECOVERY_RECIPIENT
EOF_SOPS

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"broad or noncanonical env/enc creation rule"* ]]
}

@test "duplicate exact rules are rejected" {
  cat >> .sops.yaml <<EOF_SOPS
  - path_regex: ^env/enc/dev\.env\.enc\$
    age:
      - $SECOND_RECOVERY_RECIPIENT
EOF_SOPS

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected exactly one canonical dev creation rule"* ]]
}

@test "key groups require a separate threshold-policy review" {
  cat > .sops.yaml <<EOF_SOPS
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc\$
    key_groups:
      - age:
          - $DEV_RECIPIENT
  - path_regex: ^env/enc/prod\.env\.enc\$
    age:
      - $PROD_RECIPIENT
      - $RECOVERY_RECIPIENT
EOF_SOPS

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"key_groups require a separate threshold-policy review"* ]]
}

@test "symlinked policy is rejected" {
  mv .sops.yaml real-policy.yaml
  ln -s real-policy.yaml .sops.yaml

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"policy file must not be a symlink"* ]]
}
