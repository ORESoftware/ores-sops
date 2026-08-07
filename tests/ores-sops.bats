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

  printf 'ALPHA=one\nBRAVO=dev-original\n' > env/dec/dev.env
  ores-sops encrypt dev >/dev/null
  printf 'ALPHA=one\nBRAVO=prod-original\n' > env/dec/prod.env
  ores-sops encrypt prod >/dev/null
  ores-sops lock >/dev/null
  git add .sops.yaml .gitignore env/enc/dev.env.enc env/enc/prod.env.enc
  git commit -qm baseline
}

@test "only dev and prod environment names are accepted" {
  run ores-sops use app
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported environment 'app'"* ]]
}

@test "encrypt produces ciphertext at exact approved paths" {
  grep -q '^BRAVO=' env/enc/dev.env.enc
  grep -q '^sops_mac=ENC\[' env/enc/dev.env.enc
  ! grep -q 'BRAVO=dev-original' env/enc/dev.env.enc
  [ -f env/enc/prod.env.enc ]
}

@test "use decrypts atomically and creates a relative root symlink" {
  ores-sops use dev
  [ -L .env ]
  [ "$(readlink .env)" = "env/dec/dev.env" ]
  grep -q '^BRAVO=dev-original$' env/dec/dev.env
  perms="$(stat -c '%a' env/dec/dev.env 2>/dev/null || stat -f '%Lp' env/dec/dev.env)"
  [ "$perms" = "600" ]
}

@test "switching dev to prod replaces only the managed symlink" {
  ores-sops use dev
  ores-sops use prod
  [ "$(readlink .env)" = "env/dec/prod.env" ]
  grep -q '^BRAVO=prod-original$' .env
}

@test "use refuses to overwrite an unmanaged root .env file" {
  printf 'LOCAL=keep-me\n' > .env
  run ores-sops use dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to overwrite unmanaged root .env"* ]]
  grep -q '^LOCAL=keep-me$' .env
}

@test "use refuses to replace an unmanaged root .env symlink" {
  printf 'OTHER=x\n' > other.txt
  ln -s other.txt .env
  run ores-sops use dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"unmanaged .env symlink"* ]]
  [ "$(readlink .env)" = "other.txt" ]
}

@test "failed decrypt leaves the previous complete plaintext untouched" {
  ores-sops use dev
  cp env/dec/dev.env before.env
  printf 'not-sops\n' > env/enc/dev.env.enc
  run ores-sops use --force dev
  [ "$status" -ne 0 ]
  cmp before.env env/dec/dev.env
  [ "$(readlink .env)" = "env/dec/dev.env" ]
}

@test "local plaintext edits are not silently overwritten" {
  ores-sops use dev
  printf 'ALPHA=one\nBRAVO=my-local-edit\n' > env/dec/dev.env
  run ores-sops use dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"has local edits"* ]]
  grep -q 'my-local-edit' env/dec/dev.env
}

@test "encrypt round-trips local edits and keeps explicit dotenv typing" {
  ores-sops use dev
  printf 'ALPHA=one\nBRAVO=changed\n' > env/dec/dev.env
  ores-sops encrypt dev
  ores-sops use --force dev
  grep -q '^BRAVO=changed$' env/dec/dev.env
  ! grep -q 'BRAVO=changed' env/enc/dev.env.enc
}

@test "lock removes only managed plaintext and managed root symlink" {
  ores-sops use dev
  ores-sops lock
  [ ! -e .env ]
  [ ! -e env/dec/dev.env ]
  [ ! -e env/dec/prod.env ]
  [ -f env/enc/dev.env.enc ]
  [ -f env/enc/prod.env.enc ]
}

@test "lock refuses to remove unmanaged root .env" {
  printf 'LOCAL=keep\n' > .env
  run ores-sops lock
  [ "$status" -ne 0 ]
  grep -q '^LOCAL=keep$' .env
}

@test "precommit blocks plaintext even when force-added" {
  ores-sops install-hooks
  mkdir -p nested/deeper
  printf 'SECRET=leak\n' > nested/deeper/private.env
  git add -f nested/deeper/private.env
  run git commit -qm leak
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "precommit blocks unexpected ciphertext path" {
  ores-sops install-hooks
  mkdir -p env/enc
  printf 'fake\n' > env/enc/staging.env.enc
  git add -f env/enc/staging.env.enc
  run git commit -qm unexpected
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected tracked ciphertext path"* ]]
}

@test "precommit allows the two approved ciphertext files" {
  ores-sops install-hooks
  ores-sops use dev
  printf 'ALPHA=one\nBRAVO=v2\n' > env/dec/dev.env
  ores-sops encrypt dev >/dev/null
  git add env/enc/dev.env.enc
  run git commit -qm update
  [ "$status" -eq 0 ]
}

@test "verify enforces ignore rules at root and nested depths" {
  run ores-sops verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"policy verification passed"* ]]

  git check-ignore --no-index -q .env
  git check-ignore --no-index -q one.env
  git check-ignore --no-index -q nested/two.env
  git check-ignore --no-index -q nested/deeper/three.env
  ! git check-ignore --no-index -q env/enc/dev.env.enc
  ! git check-ignore --no-index -q env/enc/prod.env.enc
}

@test "verify rejects a tracked plaintext env file" {
  printf 'SECRET=x\n' > leaked.env
  git add -f leaked.env
  run ores-sops verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"tracked plaintext dotenv paths"* ]]
}

@test "verify rejects an unexpected tracked file under env/enc" {
  printf 'x\n' > env/enc/qa.env.enc
  git add -f env/enc/qa.env.enc
  run ores-sops verify
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected tracked files under env/enc"* ]]
}

@test "init scaffolds the exact corrected allowlist and is idempotent" {
  fresh="$BATS_TEST_TMPDIR/fresh"
  mkdir -p "$fresh"
  cd "$fresh"
  git init -q .

  ores-sops init
  first="$(cat .gitignore)"
  ores-sops init
  [ "$first" = "$(cat .gitignore)" ]

  grep -Fxq '*.env' .gitignore
  grep -Fxq '*/*.env' .gitignore
  grep -Fxq '*/**/*.env' .gitignore
  grep -Fxq '/env/enc/*' .gitignore
  grep -Fxq '!/env/enc/dev.env.enc' .gitignore
  grep -Fxq '!/env/enc/prod.env.enc' .gitignore
  grep -Fq 'path_regex: ^env/enc/dev\.env\.enc$' .sops.yaml
  grep -Fq 'path_regex: ^env/enc/prod\.env\.enc$' .sops.yaml
}

@test "init does not execute shell-like text from scaffold comments" {
  fresh="$BATS_TEST_TMPDIR/no-interpolation"
  mkdir -p "$fresh"
  cd "$fresh"
  git init -q .
  run ores-sops init
  [ "$status" -eq 0 ]
  [[ "$output" != *"command not found"* ]]
}

@test "status never prints decrypted values" {
  ores-sops use dev >/dev/null
  run ores-sops status
  [ "$status" -eq 0 ]
  [[ "$output" != *"dev-original"* ]]
  [[ "$output" != *"prod-original"* ]]
}
