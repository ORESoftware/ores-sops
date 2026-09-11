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

replace_once() {
  local path="$1" old="$2" new="$3"
  python3 - "$path" "$old" "$new" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
source = path.read_text(encoding="utf-8")
count = source.count(old)
if count != 1:
    raise SystemExit(f"expected exactly one occurrence of {old!r}, found {count}")
path.write_text(source.replace(old, new, 1), encoding="utf-8")
PY
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

fixture="$(make_fixture tracked-result-suffix)"
printf '/nix/store/test-only-ores-sops\n' >"$fixture/result-debug"
git -C "$fixture" add -f result-debug
expect_fail "$fixture" 'tracked Nix result/result-* build output found'

fixture="$(make_fixture tracked-nested-result)"
mkdir -p "$fixture/nested"
printf '/nix/store/test-only-ores-sops\n' >"$fixture/nested/result-release"
git -C "$fixture" add -f nested/result-release
expect_fail "$fixture" 'tracked Nix result/result-* build output found'

fixture="$(make_fixture direct-sops)"
cat >>"$fixture/justfile" <<'EOF_BAD_SOPS'

unsafe-decrypt:
    sops decrypt env/enc/dev.env.enc
EOF_BAD_SOPS
git -C "$fixture" add justfile
expect_fail "$fixture" 'justfile must not invoke sops directly'

fixture="$(make_fixture staged-unsafe-worktree-safe)"
cat >>"$fixture/justfile" <<'EOF_STAGED_BAD_SOPS'

unsafe-decrypt:
    sops decrypt env/enc/dev.env.enc
EOF_STAGED_BAD_SOPS
git -C "$fixture" add justfile
cp "$source_root/justfile" "$fixture/justfile"
expect_fail "$fixture" 'justfile must not invoke sops directly'

fixture="$(make_fixture unstaged-unsafe-index-safe)"
cat >>"$fixture/justfile" <<'EOF_UNSTAGED_BAD_SOPS'

unsafe-decrypt:
    sops decrypt env/enc/dev.env.enc
EOF_UNSTAGED_BAD_SOPS
expect_pass "$fixture"

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
expect_fail "$fixture" 'justfile contains an unapproved recipe'

fixture="$(make_fixture approved-command-under-alias)"
cat >>"$fixture/justfile" <<'EOF_BAD_ALIAS'

alias-verify:
    ./ores-sops verify
EOF_BAD_ALIAS
git -C "$fixture" add justfile
expect_fail "$fixture" 'justfile contains an unapproved recipe: alias-verify'

fixture="$(make_fixture missing-audit-recipe)"
replace_once "$fixture/justfile" $'audit:\n' ''
git -C "$fixture" add justfile
expect_fail "$fixture" 'justfile is missing recipe: audit'

fixture="$(make_fixture altered-audit-command)"
replace_once "$fixture/justfile" \
  '    python3 tools/audit_env_contract.py' \
  '    python3 -O tools/audit_env_contract.py'
git -C "$fixture" add justfile
expect_fail "$fixture" 'justfile contains an unapproved recipe command'

fixture="$(make_fixture path-shadowed-helper)"
replace_once "$fixture/justfile" '    ./ores-sops verify' '    ores-sops verify'
git -C "$fixture" add justfile
expect_fail "$fixture" 'justfile contains an unapproved recipe command: ores-sops verify'

fixture="$(make_fixture broadened-ignore-check)"
replace_once "$fixture/justfile" \
  '    git check-ignore --quiet env/dec/runtime.env' \
  '    git check-ignore --quiet env/dec'
git -C "$fixture" add justfile
expect_fail "$fixture" 'justfile contains an unapproved recipe command'

fixture="$(make_fixture symlinked-justfile)"
rm "$fixture/justfile"
ln -s /tmp/not-a-justfile "$fixture/justfile"
git -C "$fixture" add -f justfile
expect_fail "$fixture" 'justfile must not be a symlink'

fixture="$(make_fixture executable-justfile)"
chmod 755 "$fixture/justfile"
git -C "$fixture" add justfile
expect_fail "$fixture" 'justfile must be tracked as a non-executable regular file'

fixture="$(make_fixture symlinked-gitignore)"
rm "$fixture/.gitignore"
ln -s /tmp/not-a-gitignore "$fixture/.gitignore"
git -C "$fixture" add -f .gitignore
expect_fail "$fixture" '.gitignore must be a non-executable regular file'

fixture="$tmp/outside-git"
mkdir -p "$fixture/scripts"
cp "$source_root/scripts/check-repository-boundary.sh" "$fixture/scripts/check-repository-boundary.sh"
expect_fail "$fixture" 'not inside a Git repository'

printf 'repository boundary adversarial tests: PASS\n'
