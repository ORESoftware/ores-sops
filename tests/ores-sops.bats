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

@test "every managed command recreates ignored env/dec with mode 0700" {
  commands=(
    "ensure-dec"
    "status"
    "verify"
    "precommit"
    "install-hooks --quiet"
    "lock"
  )

  for command in "${commands[@]}"; do
    rm -rf env/dec
    run bash -c "ores-sops $command"
    [ "$status" -eq 0 ]
    [ -d env/dec ]
    [ ! -L env/dec ]
    [ "$(stat -c '%a' env/dec 2>/dev/null || stat -f '%Lp' env/dec)" = "700" ]
    git check-ignore --no-index -q env/dec/runtime.env
    [ -z "$(git ls-files -- env/dec)" ]
  done
}

@test "runtime bootstrap refuses a symlinked env/dec without touching its target" {
  outside="$BATS_TEST_TMPDIR/outside-runtime-dec"
  mkdir -p "$outside"
  rm -rf env/dec
  ln -s "$outside" env/dec

  run ores-sops status
  [ "$status" -ne 0 ]
  [[ "$output" == *"managed path must not be a symlink"* ]]
  [ -z "$(find "$outside" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "only dev and prod environment names are accepted" {
  run ores-sops use app
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported environment 'app'"* ]]
}

@test "use decrypts atomically and creates a relative root symlink" {
  ores-sops use dev
  [ -L .env ]
  [ "$(readlink .env)" = "env/dec/dev.env" ]
  grep -q '^BRAVO=dev-original$' env/dec/dev.env
  [ "$(stat -c '%a' env/dec 2>/dev/null || stat -f '%Lp' env/dec)" = "700" ]
  [ "$(stat -c '%a' env/dec/dev.env 2>/dev/null || stat -f '%Lp' env/dec/dev.env)" = "600" ]
}

@test "use refuses unmanaged root env state" {
  printf 'LOCAL=keep-me\n' > .env
  run ores-sops use dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite unmanaged root .env"* ]]
  grep -q '^LOCAL=keep-me$' .env
}

@test "use refuses unmanaged root env symlink" {
  printf 'OTHER=x\n' > other.txt
  ln -s other.txt .env
  run ores-sops use dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"unmanaged .env symlink"* ]]
  [ "$(readlink .env)" = "other.txt" ]
}

@test "failed decrypt leaves previous complete plaintext untouched" {
  ores-sops use dev
  cp env/dec/dev.env before.env
  printf 'not-sops\n' > env/enc/dev.env.enc
  run ores-sops use --force dev
  [ "$status" -ne 0 ]
  cmp before.env env/dec/dev.env
}

@test "local plaintext edits are not silently overwritten" {
  ores-sops use dev
  printf 'ALPHA=one\nBRAVO=my-local-edit\n' > env/dec/dev.env
  run ores-sops use dev
  [ "$status" -ne 0 ]
  grep -q 'my-local-edit' env/dec/dev.env
}

@test "duplicate dotenv keys are rejected before encryption" {
  ores-sops use dev
  printf 'ALPHA=one\nALPHA=two\n' > env/dec/dev.env
  run ores-sops encrypt dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate variable names"* ]]
}

@test "lock removes managed plaintext and stale plaintext temp state" {
  ores-sops use dev
  printf 'SECRET=temp\n' > env/dec/.dev.env.tmp.stale
  printf 'SECRET=diff\n' > env/dec/.dev.diff-base.stale
  ores-sops lock
  [ ! -e .env ]
  [ ! -e env/dec/dev.env ]
  [ ! -e env/dec/.dev.env.tmp.stale ]
  [ ! -e env/dec/.dev.diff-base.stale ]
}

@test "precommit blocks force-added plaintext" {
  ores-sops install-hooks
  mkdir -p nested/deeper
  printf 'SECRET=leak\n' > nested/deeper/private.env
  git add -f nested/deeper/private.env
  run git commit -qm leak
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "precommit blocks staged rename into plaintext dotenv path" {
  ores-sops install-hooks
  printf 'safe\n' > safe.txt
  git add safe.txt
  git commit -qm safe
  git mv -f safe.txt renamed.env
  run git commit -qm rename
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "precommit is NUL-safe for newline filenames" {
  ores-sops install-hooks
  name=$'odd\nname.env'
  printf 'SECRET=leak\n' > "$name"
  git add -f -- "$name"
  run git commit -qm newline
  [ "$status" -ne 0 ]
}

@test "precommit blocks unexpected ciphertext path" {
  ores-sops install-hooks
  printf 'fake\n' > env/enc/staging.env.enc
  git add -f env/enc/staging.env.enc
  run git commit -qm unexpected
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected tracked ciphertext path"* ]]
}

@test "verify rejects tracked ciphertext symlink" {
  printf 'not secret\n' > "$BATS_TEST_TMPDIR/outside.txt"
  rm env/enc/dev.env.enc
  ln -s "$BATS_TEST_TMPDIR/outside.txt" env/enc/dev.env.enc
  git add -f env/enc/dev.env.enc
  run ores-sops verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"tracked symlink"* ]]
}

@test "managed directory symlink escape is rejected" {
  outside="$BATS_TEST_TMPDIR/outside-dec"
  mkdir -p "$outside"
  rm -rf env/dec
  ln -s "$outside" env/dec
  run ores-sops use dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"managed path must not be a symlink"* ]]
  [ ! -e "$outside/dev.env" ]
}

@test "init refuses symlinked policy file without modifying target" {
  fresh="$BATS_TEST_TMPDIR/policy-symlink"
  target="$BATS_TEST_TMPDIR/target-ignore"
  mkdir -p "$fresh"
  git -C "$fresh" init -q
  printf 'KEEP\n' > "$target"
  ln -s "$target" "$fresh/.gitignore"
  cd "$fresh"
  run ores-sops init
  [ "$status" -ne 0 ]
  [[ "$output" == *"policy file must not be a symlink"* ]]
  [ "$(cat "$target")" = "KEEP" ]
}

@test "custom core.hooksPath is refused by default" {
  external="$BATS_TEST_TMPDIR/external-hooks"
  git config core.hooksPath "$external"
  run ores-sops install-hooks
  [ "$status" -ne 0 ]
  [[ "$output" == *"custom core.hooksPath"* ]]
  [ ! -e "$external/pre-commit" ]
}

@test "symlinked hook file is refused" {
  mkdir -p .git/hooks
  target="$BATS_TEST_TMPDIR/hook-target"
  printf 'KEEP\n' > "$target"
  ln -s "$target" .git/hooks/pre-commit
  run ores-sops install-hooks
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlinked hook"* ]]
  [ "$(cat "$target")" = "KEEP" ]
}

@test "verify enforces root nested and suffix dotenv ignores" {
  run ores-sops verify
  [ "$status" -eq 0 ]
  git check-ignore --no-index -q one.env
  git check-ignore --no-index -q one.env.local
  git check-ignore --no-index -q nested/two.env
  git check-ignore --no-index -q nested/two.env.production
  ! git check-ignore --no-index -q env/enc/dev.env.enc
  ! git check-ignore --no-index -q env/enc/prod.env.enc
}

@test "verify rejects tracked private age identity material" {
  printf 'AGE-SE%s-KEY-1-EXAMPLE\n' 'CRET' > leak.txt
  git add leak.txt
  run ores-sops verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"private key material"* ]]
}

@test "verify rejects obvious plaintext assignment disguised as ciphertext" {
  printf 'SECRET=plaintext\nsops_mac=ENC[fake]\n' > env/enc/dev.env.enc
  git add env/enc/dev.env.enc
  run ores-sops verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"obvious plaintext assignment"* ]]
}
@test "verify accepts an exact empty assignment because it contains no plaintext secret" {
  printf 'OPTIONAL_PROVIDER_TOKEN=\nsops_mac=ENC[fake]\n' > env/enc/dev.env.enc
  git add env/enc/dev.env.enc
  run ores-sops verify
  [ "$status" -eq 0 ]
}

@test "verify still rejects quoted placeholder values" {
  printf 'OPTIONAL_PROVIDER_TOKEN=""\nsops_mac=ENC[fake]\n' > env/enc/dev.env.enc
  git add env/enc/dev.env.enc
  run ores-sops verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"obvious plaintext assignment"* ]]
}

@test "verify rejects broad env enc creation rules" {
  cat >> .sops.yaml <<EOF_SOPS
  - path_regex: ^env/enc/.*\.env\.enc\$
    age:
      - $RECIPIENT
EOF_SOPS
  run ores-sops verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"broad or noncanonical"* ]]
}

@test "init scaffolds exact policy and upgrades older ignore block" {
  fresh="$BATS_TEST_TMPDIR/fresh"
  mkdir -p "$fresh"
  cd "$fresh"
  git init -q .
  cat > .gitignore <<'EOF_OLD'
# BEGIN ores-sops dotenv policy
*.env
*/*.env
*/**/*.env
.env.*
!.env.example
/env/dec/
/env/enc/*
!/env/enc/dev.env.enc
!/env/enc/prod.env.enc
# END ores-sops dotenv policy
EOF_OLD
  ores-sops init
  grep -Fxq '*.env.*' .gitignore
  git check-ignore --no-index -q nested/app.env.local
  ! git check-ignore --no-index -q env/enc/dev.env.enc
  grep -Fq 'path_regex: ^env/enc/dev\.env\.enc$' .sops.yaml
  grep -Fq '/env/enc/*.env.enc text eol=lf' .gitattributes
  [ "$(stat -c '%a' env/dec 2>/dev/null || stat -f '%Lp' env/dec)" = "700" ]
}

@test "status never prints decrypted values" {
  ores-sops use dev >/dev/null
  run ores-sops status
  [ "$status" -eq 0 ]
  [[ "$output" != *"dev-original"* ]]
  [[ "$output" != *"prod-original"* ]]
}

# A repo scaffolded with one recipient is one lost identity away from
# unrecoverable loss of every environment, and retrofitting costs a
# `sops updatekeys` per repo across the fleet.
@test "init accepts extra recipients and lists each on both rules" {
  fresh="$BATS_TEST_TMPDIR/multi"
  mkdir -p "$fresh"
  cd "$fresh"
  git init -q .

  recovery_file="$BATS_TEST_TMPDIR/recovery.txt"
  age-keygen -o "$recovery_file" 2>/dev/null
  recovery="$(grep -o 'age1[a-z0-9]\{58\}' "$recovery_file" | head -1)"

  ores-sops init --recipient "$recovery"

  # Both the local identity and the recovery identity, on dev and on prod.
  [ "$(grep -c -- "- $RECIPIENT" .sops.yaml)" = 2 ]
  [ "$(grep -c -- "- $recovery" .sops.yaml)" = 2 ]

  # And the policy still round-trips with the recovery key alone, which is the
  # property that makes it a real second recovery path rather than decoration.
  printf 'K=v\n' > env/dec/dev.env
  ores-sops encrypt dev
  # sops infers format from the extension and `.env.enc` is not dotenv to it,
  # so the type must be explicit — the same reason the tool keeps $DOTENV.
  SOPS_AGE_KEY_FILE="$recovery_file" \
    sops --input-type dotenv --output-type dotenv --decrypt env/enc/dev.env.enc \
    | grep -Fq 'K=v'
}

@test "init takes extra recipients from the environment too" {
  fresh="$BATS_TEST_TMPDIR/fromenv"
  mkdir -p "$fresh"
  cd "$fresh"
  git init -q .

  other="$BATS_TEST_TMPDIR/other.txt"
  age-keygen -o "$other" 2>/dev/null
  other_recipient="$(grep -o 'age1[a-z0-9]\{58\}' "$other" | head -1)"

  ORES_SOPS_EXTRA_RECIPIENTS="$other_recipient" ores-sops init
  [ "$(grep -c -- "- $other_recipient" .sops.yaml)" = 2 ]
}

@test "init rejects a malformed recipient instead of writing a policy nobody can use" {
  fresh="$BATS_TEST_TMPDIR/bad"
  mkdir -p "$fresh"
  cd "$fresh"
  git init -q .

  run ores-sops init --recipient age1-not-a-real-key
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an age public key"* ]]
  [ ! -f .sops.yaml ]
}

@test "init does not repeat a recipient that is already the local identity" {
  fresh="$BATS_TEST_TMPDIR/dupe"
  mkdir -p "$fresh"
  cd "$fresh"
  git init -q .

  ores-sops init --recipient "$RECIPIENT"
  [ "$(grep -c -- "- $RECIPIENT" .sops.yaml)" = 2 ]
}
