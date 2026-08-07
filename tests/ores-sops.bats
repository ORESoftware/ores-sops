#!/usr/bin/env bats
# Behaviour tests for ores-sops.
#
# The two that matter most are the merge cases. After a merge brings in someone
# else's change, plaintext != decrypt(ciphertext) — and so it is when you
# hand-edit the plaintext. They look identical but need opposite handling, so
# both directions are pinned here.

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
  cat > .sops.yaml <<EOF
creation_rules:
  - path_regex: ^env/enc/.*\.env\.enc\$
    key_groups:
      - age:
          - $RECIPIENT
EOF
  printf '.env\n*.env\nenv/dec\n!env/enc/*.env.enc\n' > .gitignore

  printf 'ALPHA=one\nBRAVO=original\n' > env/dec/app.env
  ores-sops encrypt app >/dev/null
  git add -A && git commit -qm baseline
}

@test "encrypt produces sops ciphertext, not plaintext" {
  grep -q 'ENC\[AES256_GCM' env/enc/app.env.enc
  # Variable NAMES stay readable so diffs are reviewable; values must not.
  grep -q '^BRAVO=' env/enc/app.env.enc
  ! grep -q 'BRAVO=original' env/enc/app.env.enc
}

@test "use decrypts and links .env" {
  ores-sops use app
  [ -L .env ]
  [ "$(readlink .env)" = "env/dec/app.env" ]
  grep -q 'BRAVO=original' env/dec/app.env
}

@test "decrypted plaintext is mode 0600" {
  ores-sops use app
  perms="$(stat -c '%a' env/dec/app.env 2>/dev/null || stat -f '%Lp' env/dec/app.env)"
  [ "$perms" = "600" ]
}

@test "use refuses to clobber unencrypted local edits" {
  ores-sops use app
  printf 'ALPHA=one\nBRAVO=my_edit\n' > env/dec/app.env
  run ores-sops use app
  [ "$status" -ne 0 ]
  [[ "$output" == *"not encrypted yet"* ]]
  grep -q 'BRAVO=my_edit' env/dec/app.env
}

@test "use --force discards local edits" {
  ores-sops use app
  printf 'ALPHA=one\nBRAVO=my_edit\n' > env/dec/app.env
  ores-sops use --force app
  grep -q 'BRAVO=original' env/dec/app.env
}

@test "encrypt folds local edits back in and clears the edited state" {
  ores-sops use app
  printf 'ALPHA=one\nBRAVO=my_edit\n' > env/dec/app.env
  ores-sops encrypt app
  run ores-sops status
  [[ "$output" == *"current"* ]]
  # And it round-trips.
  ores-sops use app
  grep -q 'BRAVO=my_edit' env/dec/app.env
}

@test "merge that changes ciphertext refreshes the decrypted file" {
  ores-sops install-hooks --quiet
  ores-sops use app

  git checkout -q -b teammate
  printf 'ALPHA=one\nBRAVO=from_teammate\n' > env/dec/app.env
  ores-sops encrypt app >/dev/null
  git add env/enc/app.env.enc && git commit -qm teammate

  git checkout -q -
  ores-sops use --force app
  grep -q 'BRAVO=original' env/dec/app.env

  git merge --no-edit teammate
  grep -q 'BRAVO=from_teammate' env/dec/app.env
}

@test "merge does NOT clobber unencrypted local edits" {
  ores-sops install-hooks --quiet
  ores-sops use app

  git checkout -q -b teammate
  printf 'ALPHA=one\nBRAVO=from_teammate\n' > env/dec/app.env
  ores-sops encrypt app >/dev/null
  git add env/enc/app.env.enc && git commit -qm teammate

  git checkout -q -
  ores-sops use --force app
  printf 'ALPHA=one\nBRAVO=precious_local\n' > env/dec/app.env

  git merge --no-edit teammate
  grep -q 'BRAVO=precious_local' env/dec/app.env
}

@test "refresh is silent and successful when nothing changed" {
  ores-sops use app
  run ores-sops refresh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "refresh is a no-op when no environment is active" {
  run ores-sops refresh
  [ "$status" -eq 0 ]
}

@test "hooks never fail the git operation even without a usable key" {
  ores-sops install-hooks --quiet
  ores-sops use app
  git checkout -q -b other
  printf 'ALPHA=one\nBRAVO=x\n' > env/dec/app.env
  ores-sops encrypt app >/dev/null
  git add -A && git commit -qm other
  git checkout -q -

  # Key gone: refresh cannot decrypt, but the merge must still succeed.
  SOPS_AGE_KEY_FILE="$BATS_TEST_TMPDIR/missing.txt" run git merge --no-edit other
  [ "$status" -eq 0 ]
}

@test "install-hooks leaves a pre-existing foreign hook alone" {
  mkdir -p .git/hooks
  printf '#!/bin/sh\necho mine\n' > .git/hooks/post-merge
  chmod +x .git/hooks/post-merge
  run ores-sops install-hooks
  [[ "$output" == *"leaving it alone"* ]]
  grep -q 'echo mine' .git/hooks/post-merge
}

@test "lock removes plaintext, stamps and the symlink" {
  ores-sops use app
  ores-sops lock
  [ ! -e env/dec/app.env ]
  [ ! -e .env ]
  [ -z "$(ls -A env/dec 2>/dev/null)" ]
  # Ciphertext survives.
  [ -f env/enc/app.env.enc ]
}

@test "status marks the active environment and reports stale" {
  ores-sops use app
  run ores-sops status
  [[ "$output" == *"* app"* ]]

  # Change ciphertext behind its back.
  printf 'ALPHA=one\nBRAVO=changed\n' > env/dec/other.env
  ores-sops encrypt other >/dev/null
  cp env/enc/other.env.enc env/enc/app.env.enc
  run ores-sops status
  [[ "$output" == *"STALE"* ]]
}

@test "init is idempotent and does not overwrite .sops.yaml" {
  mkdir -p "$BATS_TEST_TMPDIR/fresh"
  cd "$BATS_TEST_TMPDIR/fresh"
  git init -q .
  printf 'original\n' > .sops.yaml
  ores-sops init
  grep -q '^original$' .sops.yaml
  grep -q 'env/dec' .gitignore
  # Second run changes nothing further.
  run ores-sops init
  [[ "$output" == *"kept existing"* ]]
}

@test "gitignore from init actually blocks plaintext but allows ciphertext" {
  mkdir -p "$BATS_TEST_TMPDIR/g"
  cd "$BATS_TEST_TMPDIR/g"
  git init -q .
  ores-sops init >/dev/null
  mkdir -p env/enc env/dec
  touch env/dec/prod.env env/enc/prod.env.enc .env
  git check-ignore -q env/dec/prod.env
  git check-ignore -q .env
  ! git check-ignore -q env/enc/prod.env.enc
}

@test "encrypt leaves status current even when the edit had blank lines" {
  # sops' dotenv writer normalizes on round-trip (blank lines are dropped), so
  # keeping the hand-edited bytes would leave plaintext != decrypt(ciphertext)
  # and report STALE immediately after a successful encrypt.
  ores-sops use app
  printf 'ALPHA=one\n\nBRAVO=two\n\n\nCHARLIE=three\n' > env/dec/app.env
  ores-sops encrypt app
  run ores-sops status
  [[ "$output" == *"current"* ]]
  [[ "$output" != *"STALE"* ]]
  # Values survive the normalization.
  grep -q '^CHARLIE=three$' env/dec/app.env
  grep -q '^BRAVO=two$' env/dec/app.env
}

@test "encrypt then refresh is a silent no-op" {
  ores-sops use app
  printf 'ALPHA=one\n\nBRAVO=changed\n' > env/dec/app.env
  ores-sops encrypt app >/dev/null
  run ores-sops refresh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "encrypt refuses to write an empty plaintext over existing secrets" {
  ores-sops use app
  : > env/dec/app.env
  run ores-sops encrypt app
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to encrypt an empty file"* ]]
  # The ciphertext is untouched and still holds the secret.
  ores-sops use --force app
  grep -q 'BRAVO=original' env/dec/app.env
}

@test "encrypt refuses a comment-only plaintext over existing secrets" {
  ores-sops use app
  printf '# everything got deleted\n' > env/dec/app.env
  run ores-sops encrypt app
  [ "$status" -ne 0 ]
  [[ "$output" == *"Refusing to encrypt an empty file"* ]]
}

@test "encrypt --allow-empty deliberately wipes an environment" {
  ores-sops use app
  : > env/dec/app.env
  ores-sops encrypt --allow-empty app
  run ores-sops status
  [ "$status" -eq 0 ]
  [[ "$output" != *"BRAVO"* ]]
}

@test "pre-commit BLOCKS a staged plaintext env file" {
  ores-sops install-hooks --quiet
  ores-sops use app
  # Force past .gitignore, the way someone would with `git add -f`.
  git add -f env/dec/app.env
  run git commit -qm "oops"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED"* ]]
  # Nothing was committed.
  run git log --oneline -1
  [[ "$output" == *"baseline"* ]]
}

@test "pre-commit BLOCKS a staged root .env" {
  ores-sops install-hooks --quiet
  printf 'SECRET=leaked\n' > .env
  git add -f .env
  run git commit -qm "oops"
  [ "$status" -ne 0 ]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "pre-commit does NOT block committing ciphertext" {
  ores-sops install-hooks --quiet
  ores-sops use app
  printf 'ALPHA=one\nBRAVO=v2\n' > env/dec/app.env
  ores-sops encrypt app >/dev/null
  git add env/enc/app.env.enc
  run git commit -qm "update secret"
  [ "$status" -eq 0 ]
}

@test "pre-commit WARNS when input differs from committed output, but allows it" {
  ores-sops install-hooks --quiet
  ores-sops use app
  # Edit the plaintext input without encrypting it.
  printf 'ALPHA=one\nBRAVO=not_yet_encrypted\n' > env/dec/app.env
  # Commit something unrelated.
  printf 'hello\n' > README.md
  git add README.md
  run git commit -m "unrelated change"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"differs from"* ]]
}

@test "pre-commit is silent when input and output agree" {
  ores-sops install-hooks --quiet
  ores-sops use app
  printf 'hello\n' > README.md
  git add README.md
  run git commit -m "unrelated change"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
  [[ "$output" != *"BLOCKED"* ]]
}

@test "install-hooks leaves a pre-existing foreign pre-commit alone" {
  mkdir -p .git/hooks
  printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit
  run ores-sops install-hooks
  [[ "$output" == *"pre-commit exists and is not ours"* ]]
}

@test "unknown command fails closed" {
  run ores-sops not-a-command
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
}
