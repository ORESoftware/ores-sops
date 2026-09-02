#!/usr/bin/env bats

make_recipient() {
  local character="$1"
  printf 'age1'
  printf '%058d' 0 | tr '0' "$character"
}

write_stage_policy() {
  local dev_block="$1" stage_block="$2" prod_block="$3"
  cat > .sops.yaml <<EOF_SOPS
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc\$
    age:
$dev_block
  - path_regex: ^env/enc/stage\.env\.enc\$
    age:
$stage_block
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
  export TESTDIR="$BATS_TEST_TMPDIR/stage-access-audit"
  export DEV_ONLY="$(make_recipient d)"
  export RELEASE="$(make_recipient l)"
  export STAGE_ONLY="$(make_recipient s)"
  export PROD_ONLY="$(make_recipient p)"
  export RECOVERY="$(make_recipient r)"

  mkdir -p "$TESTDIR"
  cd "$TESTDIR"

  write_stage_policy "      - $DEV_ONLY
      - $RELEASE
      - $RECOVERY" "      - $RELEASE
      - $STAGE_ONLY
      - $RECOVERY" "      - $PROD_ONLY
      - $RECOVERY"
}

@test "three-environment matrix permits dev-only and stage-not-prod identities" {
  run ores-sops-access-audit check --policy-only
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev=3, stage=3, prod=2"* ]]
  [[ "$output" == *"dev-only=1"* ]]
  [[ "$output" == *"stage-not-prod=2"* ]]
  [[ "$output" == *"prod-only=1"* ]]
  [[ "$output" != *"$DEV_ONLY"* ]]
}

@test "show includes stage only when its exact rule exists" {
  run ores-sops-access-audit show
  [ "$status" -eq 0 ]
  [[ "$output" == *$'stage\t'"$STAGE_ONLY"* ]]
  [[ "$output" == *$'dev\t'"$DEV_ONLY"* ]]
  [[ "$output" == *$'prod\t'"$PROD_ONLY"* ]]
}

@test "dev must contain an identity omitted from both stage and prod" {
  write_stage_policy "      - $RELEASE
      - $RECOVERY" "      - $RELEASE
      - $STAGE_ONLY
      - $RECOVERY" "      - $PROD_ONLY
      - $RECOVERY"

  run ores-sops-access-audit check --policy-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"dev has no dev-only recipient"* ]]
}

@test "stage must contain an identity omitted from prod" {
  write_stage_policy "      - $DEV_ONLY
      - $RECOVERY" "      - $PROD_ONLY
      - $RECOVERY" "      - $PROD_ONLY
      - $RECOVERY"

  run ores-sops-access-audit check --policy-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage has no non-production recipient"* ]]
}

@test "all three ciphertext recipient sets are compared with desired policy" {
  write_ciphertext dev "$RECOVERY" "$RELEASE" "$DEV_ONLY"
  write_ciphertext stage "$STAGE_ONLY" "$RECOVERY" "$RELEASE"
  write_ciphertext prod "$RECOVERY" "$PROD_ONLY"

  run ores-sops-access-audit check --require-ciphertext
  [ "$status" -eq 0 ]
  [[ "$output" == *"checked for 3 file(s)"* ]]
}

@test "stage ciphertext drift fails without revealing recipients" {
  write_ciphertext dev "$DEV_ONLY" "$RELEASE" "$RECOVERY"
  write_ciphertext stage "$PROD_ONLY" "$RECOVERY"
  write_ciphertext prod "$PROD_ONLY" "$RECOVERY"

  run ores-sops-access-audit check --require-ciphertext
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage ciphertext recipients differ from .sops.yaml"* ]]
  [[ "$output" != *"$PROD_ONLY"* ]]
}

@test "stage ciphertext without exact stage rule fails closed" {
  cat > .sops.yaml <<EOF_SOPS
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc\$
    age:
      - $DEV_ONLY
      - $RECOVERY
  - path_regex: ^env/enc/prod\.env\.enc\$
    age:
      - $PROD_ONLY
      - $RECOVERY
EOF_SOPS
  write_ciphertext stage "$STAGE_ONLY" "$RECOVERY"

  run ores-sops-access-audit check
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage ciphertext exists without an exact stage rule"* ]]
}

@test "duplicate exact stage rules fail closed" {
  cat >> .sops.yaml <<EOF_SOPS
  - path_regex: ^env/enc/stage\.env\.enc\$
    age:
      - $STAGE_ONLY
      - $RECOVERY
EOF_SOPS

  run ores-sops-access-audit check --policy-only
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected at most one canonical stage creation rule"* ]]
}
