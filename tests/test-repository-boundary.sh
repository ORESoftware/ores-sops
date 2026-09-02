#!/usr/bin/env bash
set -euo pipefail

source_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

make_fixture() {
  local name="$1"
  local fixture="$tmp/$name"
  mkdir -p "$fixture/scripts"
  cp "$source_root/justfile" "$fixture/justfile"
  cp "$source_root/.gitignore" "$fixture/.gitignore"
  cp "$source_root/scripts/check-repository-boundary.sh" "$fixture/scripts/check-repository-boundary.sh"
  chmod 755 "$fixture/scripts/check-repository-boundary.sh"
  git -C "$fixture" init -q
  git -C "$fixture" config user.email boundary@example.invalid
  git -C "$fixture" config user.name boundary-test
  git -C "$fixture" add .gitignore justfile scripts/check-repository-boundary.sh
  printf '%s\n' "$fixture"
}

expect_pass() {
  local fixture="$1"
  local output
  output="$(cd "$fixture" && bash scripts/check-repository-boundary.sh 2>&1)"
  case "$output" in
    *'repository boundary: PASS'*) ;;
    *) printf 'expected pass, got: %s\n' "$output" >&2; return 1 ;;
  esac
}

expect_fail() {
  local fixture="$1" expected="$2" output
  if output="$(cd "$fixture" && bash scripts/check-repository-boundary.sh 2>&1)"; then
    printf 'expected failure containing %s\n' "$expected" >&2
    return 1
  fi
  case "$output" in
    *"$expected"*) ;;
    *) printf 'expected %s, got: %s\n' "$expected" "$output" >&2; return 1 ;;
  esac
}

fixture="$(make_fixture baseline)"
expect_pass "$fixture"

fixture="$(make_fixture tracked-result)"
printf '/nix/store/test-only-ores-sops\n' >"$fixture/result"
git -C "$fixture" add -f result
expect_fail "$fixture" 'tracked Nix result/result-* build output found'

fixture="$(make_fixture direct-sops)"
cat >>"$fixture/justfile" <<'EOF_BAD_SOPS'

unsafe-decrypt:
    sops decrypt env/enc/dev.env.enc
EOF_BAD_SOPS
git -C "$fixture" add justfile
expect_fail "$fixture" 'justfile must not invoke sops directly'

fixture="$(make_fixture direct-runtime-directory)"
cat >>"$fixture/justfile" <<'EOF_BAD_DIRECTORY'

unsafe-directory:
    mkdir -p env/dec
EOF_BAD_DIRECTORY
git -C "$fixture" add justfile
expect_fail "$fixture" 'justfile must not create or chmod env/dec directly'

fixture="$(make_fixture arbitrary-command)"
cat >>"$fixture/justfile" <<'EOF_BAD_COMMAND'

unsafe-command:
    printf should-not-run
EOF_BAD_COMMAND
git -C "$fixture" add justfile
expect_fail "$fixture" 'justfile contains an unapproved recipe command'

fixture="$(make_fixture symlinked-justfile)"
rm "$fixture/justfile"
ln -s /tmp/not-a-justfile "$fixture/justfile"
git -C "$fixture" add -f justfile
expect_fail "$fixture" 'justfile must not be a symlink'

printf 'repository boundary adversarial tests: PASS\n'
