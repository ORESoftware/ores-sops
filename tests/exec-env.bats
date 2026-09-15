#!/usr/bin/env bats

setup() {
  export TESTDIR="$BATS_TEST_TMPDIR/repo"
  export SOPS_AGE_KEY_FILE="$BATS_TEST_TMPDIR/age.txt"
  export ORES_SOPS_TELEMETRY=0
  age-keygen -o "$SOPS_AGE_KEY_FILE" 2>/dev/null
  RECIPIENT="$(grep -o 'age1[a-z0-9]\{58\}' "$SOPS_AGE_KEY_FILE" | head -1)"

  mkdir -p "$TESTDIR/env/enc" "$TESTDIR/env/dec"
  chmod 700 "$TESTDIR/env/dec"
  cd "$TESTDIR"
  git init -q .
  git config user.email t@example.com
  git config user.name t
  git config commit.gpgsign false

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

  printf 'EXEC_FIXTURE=synthetic-exec-value\n' > env/dec/dev.env
  ores-sops encrypt dev >/dev/null
  printf 'EXEC_FIXTURE=synthetic-prod-value\n' > env/dec/prod.env
  ores-sops encrypt prod >/dev/null
  ores-sops lock >/dev/null
}

assert_status_is() {
  local expected="$1"
  if [ "$status" -ne "$expected" ]; then
    printf 'exec-env synthetic failure: expected=%s actual=%s output=%q\n' "$expected" "$status" "$output" >&3
  fi
  [ "$status" -eq "$expected" ]
}

@test "exec exposes decrypted values without materializing managed plaintext" {
  [ ! -e .env ]
  [ ! -e env/dec/dev.env ]

  run ores-sops exec --env dev -- sh -c 'test "$EXEC_FIXTURE" = synthetic-exec-value && printf admitted'
  assert_status_is 0
  [ "$output" = "admitted" ]

  [ ! -e .env ]
  [ ! -e env/dec/dev.env ]
  [ ! -e env/dec/.dev.env.sha256 ]
}

@test "exec preserves downstream argv without shell injection" {
  payload="a'b;\$(touch $TESTDIR/should-not-exist)"
  run ores-sops exec --environment=dev -- sh -c 'test "$1" = "$EXPECTED"' _ "$payload"
  # EXPECTED is ambient, not decrypted; this first run should fail while still
  # proving the payload was passed as data rather than evaluated by the shell.
  [ "$status" -ne 0 ]
  [ ! -e "$TESTDIR/should-not-exist" ]

  run env EXPECTED="$payload" ores-sops exec --environment=dev -- sh -c 'test "$1" = "$EXPECTED"' _ "$payload"
  assert_status_is 0
  [ ! -e "$TESTDIR/should-not-exist" ]
}

@test "exec preserves child exit status" {
  run ores-sops exec --env dev -- sh -c 'exit 37'
  assert_status_is 37
}

@test "exec requires explicit environment delimiter and command" {
  run ores-sops exec -- sh -c true
  [ "$status" -ne 0 ]
  [[ "$output" == *"required environment is missing"* ]]

  run ores-sops exec --env dev
  [ "$status" -ne 0 ]
  if [[ "$output" != *"bare -- followed by a command"* ]]; then
    printf 'exec-env synthetic failure: missing-command output=%q\n' "$output" >&3
  fi
  [[ "$output" == *"bare -- followed by a command"* ]]

  run ores-sops exec --env dev --
  [ "$status" -ne 0 ]
  if [[ "$output" != *"bare -- followed by a command"* ]]; then
    printf 'exec-env synthetic failure: empty-command output=%q\n' "$output" >&3
  fi
  [[ "$output" == *"bare -- followed by a command"* ]]
}

@test "exec rejects noncanonical environment without reflecting it" {
  invalid='qa-noncanonical-sensitive-label'
  run ores-sops exec --env "$invalid" -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment must be dev, stage, or prod"* || "$output" == *"command-line admission failed"* ]]
  [[ "$output" != *"$invalid"* ]]
}

@test "exec rejects stage when exact stage policy is absent" {
  run ores-sops exec --env stage -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"selected encrypted environment is missing or unsafe"* || "$output" == *"no exact SOPS creation rule"* ]]
}

@test "exec rejects ciphertext symlink without reading its target" {
  outside="$BATS_TEST_TMPDIR/outside.env.enc"
  cp env/enc/dev.env.enc "$outside"
  rm env/enc/dev.env.enc
  ln -s "$outside" env/enc/dev.env.enc

  run ores-sops exec --env dev -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or unsafe"* ]]
  [ ! -e env/dec/dev.env ]
}

@test "exec refuses downstream control characters before SOPS" {
  command_with_newline=$'printf\nunsafe'
  run ores-sops exec --env dev -- "$command_with_newline"
  [ "$status" -ne 0 ]
  [[ "$output" == *"command-line admission failed"* ]]
}
