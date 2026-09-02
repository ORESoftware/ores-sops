from __future__ import annotations

import re
from pathlib import Path


def replace_function(path: str, name: str, next_name: str, replacement: str) -> None:
    target = Path(path)
    text = target.read_text(encoding="utf-8")
    pattern = re.compile(
        rf"(?ms)^{re.escape(name)}\(\) \{{.*?^\}}\n\n(?={re.escape(next_name)}\(\) \{{)"
    )
    updated, count = pattern.subn(lambda _: replacement.rstrip() + "\n\n", text, count=1)
    if count != 1:
        raise SystemExit(f"{path}:{name}: expected one function block, found {count}")
    target.write_text(updated, encoding="utf-8")


def replace_once(path: str, old: str, new: str, label: str) -> None:
    target = Path(path)
    text = target.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}:{label}: expected one match, found {count}")
    target.write_text(text.replace(old, new, 1), encoding="utf-8")


replace_function(
    "scripts/fleet-audit.sh",
    "sops_rule_state",
    "ignore_contract_state",
    r'''sops_rule_state() {
  local file="$1" line trimmed dev=0 stage=0 prod=0 broad=0
  if [ ! -e "$file" ]; then
    printf 'missing\n'
    return
  fi
  if ! is_tracked "$file"; then
    printf 'untracked\n'
    return
  fi
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    printf 'invalid\n'
    return
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '- '*) trimmed="${trimmed#- }" ;;
    esac
    case "$trimmed" in
      'path_regex: ^env/enc/dev\.env\.enc$') dev=$((dev + 1)) ;;
      'path_regex: ^env/enc/stage\.env\.enc$') stage=$((stage + 1)) ;;
      'path_regex: ^env/enc/prod\.env\.enc$') prod=$((prod + 1)) ;;
      path_regex:*env/enc*) broad=1 ;;
    esac
  done <"$file"

  if [ "$broad" -eq 1 ]; then
    printf 'broad\n'
  elif [ "$dev" -ne 1 ] || [ "$prod" -ne 1 ] || [ "$stage" -gt 1 ]; then
    printf 'missing\n'
  elif [ "$stage" -eq 1 ]; then
    printf 'exact-stage\n'
  else
    printf 'exact\n'
  fi
}''',
)

replace_once(
    "scripts/access-audit.sh",
    '''      '- path_regex: ^env/enc/dev\\.env\\.enc$')
        DEV_RULES=$((DEV_RULES + 1))
        current="dev"
        section=""
        ;;''',
    '''      '- path_regex: ^env/enc/dev\\.env\\.enc$')
        DEV_RULES=$((DEV_RULES + 1))
        [ "$DEV_RULES" -eq 1 ] || fail "expected exactly one canonical dev creation rule"
        current="dev"
        section=""
        ;;''',
    "dev duplicate rule guard",
)
replace_once(
    "scripts/access-audit.sh",
    '''      '- path_regex: ^env/enc/stage\\.env\\.enc$')
        STAGE_RULES=$((STAGE_RULES + 1))
        current="stage"
        section=""
        ;;''',
    '''      '- path_regex: ^env/enc/stage\\.env\\.enc$')
        STAGE_RULES=$((STAGE_RULES + 1))
        [ "$STAGE_RULES" -le 1 ] || fail "expected at most one canonical stage creation rule"
        current="stage"
        section=""
        ;;''',
    "stage duplicate rule guard",
)
replace_once(
    "scripts/access-audit.sh",
    '''      '- path_regex: ^env/enc/prod\\.env\\.enc$')
        PROD_RULES=$((PROD_RULES + 1))
        current="prod"
        section=""
        ;;''',
    '''      '- path_regex: ^env/enc/prod\\.env\\.enc$')
        PROD_RULES=$((PROD_RULES + 1))
        [ "$PROD_RULES" -eq 1 ] || fail "expected exactly one canonical prod creation rule"
        current="prod"
        section=""
        ;;''',
    "prod duplicate rule guard",
)

atomic_test = r'''
@test "unauthorized stage and prod activation leave dev plaintext and symlink untouched" {
  SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops use dev >/dev/null
  cp env/dec/dev.env "$BATS_TEST_TMPDIR/dev-before.env"
  before_target="$(readlink .env)"

  run env SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops use stage
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not decrypt 'stage'"* ]]
  [ ! -e env/dec/stage.env ]
  [ "$(readlink .env)" = "$before_target" ]
  cmp "$BATS_TEST_TMPDIR/dev-before.env" env/dec/dev.env

  run env SOPS_AGE_KEY_FILE="$DEV_KEY" ores-sops use prod
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not decrypt 'prod'"* ]]
  [ ! -e env/dec/prod.env ]
  [ "$(readlink .env)" = "$before_target" ]
  cmp "$BATS_TEST_TMPDIR/dev-before.env" env/dec/dev.env
}

'''
replace_once(
    "tests/stage-lifecycle.bats",
    '@test "stage activation is atomic and uses the managed relative symlink" {',
    atomic_test + '@test "stage activation is atomic and uses the managed relative symlink" {',
    "unauthorized activation test insertion",
)

replace_once(
    "tests/stage-fleet-audit.bats",
    "[[ \"$output\" == *$'\\t1\\t0\\texact\\t'* ]]",
    "[[ \"$output\" == *$'\\tconflicting\\t0\\t1\\t0\\texact\\t'* ]]",
    "full conflicting fleet row assertion",
)
