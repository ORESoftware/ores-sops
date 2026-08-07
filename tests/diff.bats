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

  mkdir -p env/enc env/dec
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
!.env.example
/env/dec/
/env/enc/*
!/env/enc/dev.env.enc
!/env/enc/prod.env.enc
EOF_IGNORE

  printf 'ALPHA=one\nBRAVO=old-secret\nREMOVE_ME=hidden\n' > env/dec/dev.env
  ores-sops encrypt dev >/dev/null
  ores-sops use --force dev >/dev/null
}

@test "diff reports only key names, never values" {
  printf 'ALPHA=one\nBRAVO=new-super-secret\nCHARLIE=another-secret\n' > env/dec/dev.env

  run ores-sops diff dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"~ BRAVO"* ]]
  [[ "$output" == *"+ CHARLIE"* ]]
  [[ "$output" == *"- REMOVE_ME"* ]]
  [[ "$output" != *"old-secret"* ]]
  [[ "$output" != *"new-super-secret"* ]]
  [[ "$output" != *"another-secret"* ]]
  [[ "$output" == *"values intentionally hidden"* ]]
}

@test "diff reports no edits without exposing values" {
  run ores-sops diff dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"no local edits"* ]]
  [[ "$output" != *"old-secret"* ]]
}

@test "diff rejects noncanonical environment names" {
  run ores-sops diff staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported environment 'staging'"* ]]
}
