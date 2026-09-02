from __future__ import annotations

import re
from pathlib import Path


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, content: str) -> None:
    Path(path).write_text(content, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one exact match, found {count}")
    return text.replace(old, new, 1)


def replace_function(text: str, name: str, next_name: str, replacement: str) -> str:
    pattern = re.compile(
        rf"(?ms)^{re.escape(name)}\(\) \{{.*?^\}}\n\n(?={re.escape(next_name)}\(\) \{{)"
    )
    updated, count = pattern.subn(replacement.rstrip() + "\n\n", text, count=1)
    if count != 1:
        raise SystemExit(f"{name}: expected one function block, found {count}")
    return updated


path = "ores-sops"
text = read(path)
text = replace_once(
    text,
    "#   env/enc/dev.env.enc\n#   env/enc/prod.env.enc\n#\n# Local plaintext:\n#   env/dec/dev.env\n#   env/dec/prod.env\n#   .env -> env/dec/<dev|prod>.env",
    "#   env/enc/dev.env.enc\n#   env/enc/stage.env.enc   # optional, exact-rule opt-in\n#   env/enc/prod.env.enc\n#\n# Local plaintext:\n#   env/dec/dev.env\n#   env/dec/stage.env       # optional, runtime-only\n#   env/dec/prod.env\n#   .env -> env/dec/<dev|stage|prod>.env",
    "helper header",
)
text = replace_once(text, 'VERSION="0.3.2"', 'VERSION="0.4.0"', "helper version")
text = replace_once(
    text,
    '''need_env() {
  case "${1:-}" in
    dev|prod) ;;
    "") fail "missing environment name; expected dev or prod" ;;
    *) fail "unsupported environment '$1'; expected dev or prod" ;;
  esac
}''',
    '''need_env() {
  case "${1:-}" in
    dev|stage|prod) ;;
    "") fail "missing environment name; expected dev, stage, or prod" ;;
    *) fail "unsupported environment '$1'; expected dev, stage, or prod" ;;
  esac
}''',
    "need_env",
)
text = replace_once(
    text,
    '''enc_path() { need_env "$1"; printf '%s/env/enc/%s.env.enc' "$(repo_root)" "$1"; }
dec_path() { need_env "$1"; printf '%s/env/dec/%s.env' "$(repo_root)" "$1"; }
stamp_path() { need_env "$1"; printf '%s/env/dec/.%s.env.sha256' "$(repo_root)" "$1"; }''',
    '''enc_path() { need_env "$1"; printf '%s/env/enc/%s.env.enc' "$(repo_root)" "$1"; }
dec_path() { need_env "$1"; printf '%s/env/dec/%s.env' "$(repo_root)" "$1"; }
stamp_path() { need_env "$1"; printf '%s/env/dec/.%s.env.sha256' "$(repo_root)" "$1"; }

count_exact_sops_rule() {
  local environment="$1" root
  need_env "$environment"
  root="$(repo_root)"
  [ -f "$root/.sops.yaml" ] || { printf '0\n'; return; }
  awk -v expected="path_regex: ^env/enc/${environment}\\.env\\.enc$" '
    {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/^[[:space:]]*/, "", line)
      if (line == expected) count++
    }
    END { print count + 0 }
  ' "$root/.sops.yaml"
}

stage_rule_present() {
  [ "$(count_exact_sops_rule stage)" -eq 1 ]
}

stage_configured() {
  local root target=""
  root="$(repo_root)"
  stage_rule_present && return 0
  { [ -e "$root/env/enc/stage.env.enc" ] || [ -L "$root/env/enc/stage.env.enc" ]; } && return 0
  { [ -e "$root/env/dec/stage.env" ] || [ -L "$root/env/dec/stage.env" ]; } && return 0
  if [ -L "$root/.env" ]; then
    target="$(readlink "$root/.env")"
    [ "$target" = "env/dec/stage.env" ] && return 0
  fi
  return 1
}

managed_envs() {
  printf 'dev\n'
  stage_configured && printf 'stage\n'
  printf 'prod\n'
}''',
    "path helpers",
)
text = replace_once(
    text,
    '''  case "$target" in
    env/dec/dev.env) printf 'dev\n' ;;
    env/dec/prod.env) printf 'prod\n' ;;
    *) return 0 ;;
  esac''',
    '''  case "$target" in
    env/dec/dev.env) printf 'dev\n' ;;
    env/dec/stage.env) printf 'stage\n' ;;
    env/dec/prod.env) printf 'prod\n' ;;
    *) return 0 ;;
  esac''',
    "active_name",
)
text = replace_once(
    text,
    '      env/dec/dev.env|env/dec/prod.env) ;;',
    '      env/dec/dev.env|env/dec/stage.env|env/dec/prod.env) ;;',
    "root env allowlist",
)
text = replace_function(
    text,
    "cmd_status",
    "cmd_refresh",
    r'''cmd_status() {
  local name mark active
  assert_managed_tree_safe
  active="$(active_name || true)"
  while IFS= read -r name; do
    assert_managed_file_safe "$(enc_path "$name")"
    assert_managed_file_safe "$(dec_path "$name")"
    mark="  "
    [ "$active" = "$name" ] && mark="* "
    if [ ! -f "$(enc_path "$name")" ]; then
      printf '%s%-6s missing ciphertext\n' "$mark" "$name"
    elif [ ! -f "$(dec_path "$name")" ]; then
      printf '%s%-6s encrypted only\n' "$mark" "$name"
    elif has_local_edits "$name"; then
      printf '%s%-6s EDITED — local plaintext differs from managed baseline\n' "$mark" "$name"
    elif ciphertext_differs "$name"; then
      printf '%s%-6s STALE — run ores-sops refresh\n' "$mark" "$name"
    else
      printf '%s%-6s current\n' "$mark" "$name"
    fi
  done < <(managed_envs)
}''',
)
text = replace_function(
    text,
    "cmd_lock",
    "is_plaintext_env_path",
    r'''cmd_lock() {
  local root target name f
  root="$(repo_root)"
  assert_managed_tree_safe
  if [ -L "$root/.env" ]; then
    target="$(readlink "$root/.env")"
    case "$target" in
      env/dec/dev.env|env/dec/stage.env|env/dec/prod.env) rm -f "$root/.env" ;;
      *) fail "refusing to remove unmanaged .env symlink -> $target" ;;
    esac
  elif [ -e "$root/.env" ]; then
    fail "refusing to remove unmanaged root .env"
  fi
  for name in dev stage prod; do
    assert_managed_file_safe "$(dec_path "$name")"
    assert_managed_file_safe "$(stamp_path "$name")"
    rm -f "$(dec_path "$name")" "$(stamp_path "$name")"
  done
  for f in \
    "$root"/env/dec/.dev.env.tmp.* "$root"/env/dec/.stage.env.tmp.* "$root"/env/dec/.prod.env.tmp.* \
    "$root"/env/dec/.dev.diff-base.* "$root"/env/dec/.stage.diff-base.* "$root"/env/dec/.prod.diff-base.* \
    "$root"/env/dec/.dev.stamp.* "$root"/env/dec/.stage.stamp.* "$root"/env/dec/.prod.stamp.*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    rm -f -- "$f"
  done
  printf 'ores-sops: removed managed plaintext, temp state, and root .env symlink\n'
}''',
)
text = replace_function(
    text,
    "cmd_precommit",
    "check_ignored",
    r'''cmd_precommit() {
  local root f blocked=0 mode shown
  root="$(repo_root)"
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    mode="$(git -C "$root" ls-files -s -- "$f" | awk 'NR==1 { print $1 }')"
    shown="$(log_path "$f")"
    case "$f" in
      env/enc/dev.env.enc|env/enc/prod.env.enc)
        if [ "$mode" = "120000" ]; then
          printf 'ores-sops: BLOCKED — approved ciphertext path is a symlink: %s\n' "$shown" >&2
          blocked=1
        fi
        ;;
      env/enc/stage.env.enc)
        if ! stage_rule_present; then
          printf 'ores-sops: BLOCKED — stage ciphertext requires an exact stage SOPS rule: %s\n' "$shown" >&2
          blocked=1
        elif [ "$mode" = "120000" ]; then
          printf 'ores-sops: BLOCKED — approved ciphertext path is a symlink: %s\n' "$shown" >&2
          blocked=1
        fi
        ;;
      env/enc/*)
        printf 'ores-sops: BLOCKED — unexpected tracked ciphertext path: %s\n' "$shown" >&2
        blocked=1
        ;;
      .sops.yaml|.gitignore|.gitattributes|.env.example)
        if [ "$mode" = "120000" ]; then
          printf 'ores-sops: BLOCKED — policy file must not be a symlink: %s\n' "$shown" >&2
          blocked=1
        fi
        ;;
      *)
        if is_plaintext_env_path "$f"; then
          printf 'ores-sops: BLOCKED — plaintext dotenv path staged: %s\n' "$shown" >&2
          blocked=1
        fi
        ;;
    esac
  done < <(git -C "$root" diff --cached --name-only -z --diff-filter=ACMRTUXB 2>/dev/null || true)
  [ "$blocked" = 0 ] || return 1
}''',
)
text = replace_function(
    text,
    "verify_sops_rules",
    "verify_no_private_material",
    r'''verify_sops_rules() {
  local root line trimmed rule dev_rules stage_rules prod_rules
  root="$(repo_root)"
  dev_rules="$(count_exact_sops_rule dev)"
  stage_rules="$(count_exact_sops_rule stage)"
  prod_rules="$(count_exact_sops_rule prod)"

  [ "$dev_rules" -eq 1 ] || fail "expected exactly one exact dev SOPS creation rule"
  [ "$prod_rules" -eq 1 ] || fail "expected exactly one exact prod SOPS creation rule"
  [ "$stage_rules" -le 1 ] || fail "expected at most one exact stage SOPS creation rule"

  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    rule="$trimmed"
    case "$rule" in
      '- '*) rule="${rule#- }" ;;
    esac
    case "$rule" in
      'path_regex: ^env/enc/dev\.env\.enc$'|\
      'path_regex: ^env/enc/stage\.env\.enc$'|\
      'path_regex: ^env/enc/prod\.env\.enc$') ;;
      path_regex:*env/enc*) fail "broad or noncanonical env/enc SOPS creation rule is not allowed" ;;
    esac
  done <"$root/.sops.yaml"

  if [ "$stage_rules" -eq 0 ] && stage_configured; then
    fail "stage artifacts require exactly one stage SOPS creation rule"
  fi
}''',
)
text = replace_function(
    text,
    "cmd_verify",
    "cmd_install_hooks",
    r'''cmd_verify() {
  local root name file mode target f shown stage_enabled=0
  root="$(repo_root)"
  assert_managed_tree_safe
  assert_policy_path_safe
  [ -f "$root/.gitignore" ] || fail "missing .gitignore"
  [ -f "$root/.gitattributes" ] || fail "missing .gitattributes"
  [ -f "$root/.sops.yaml" ] || fail "missing .sops.yaml"

  verify_sops_rules
  stage_rule_present && stage_enabled=1

  check_ignored ".env"
  check_ignored "sample.env"
  check_ignored "sample.env.local"
  check_ignored "nested/sample.env"
  check_ignored "nested/sample.env.local"
  check_ignored "nested/deeper/sample.env"
  check_ignored "env/dec/dev.env"
  check_ignored "env/dec/stage.env"
  check_ignored "env/dec/prod.env"
  check_not_ignored "env/enc/dev.env.enc"
  check_not_ignored "env/enc/prod.env.enc"
  if [ "$stage_enabled" -eq 1 ]; then
    check_not_ignored "env/enc/stage.env.enc"
  fi

  grep -Fq '/env/enc/*.env.enc text eol=lf' "$root/.gitattributes" || fail "missing ciphertext LF normalization in .gitattributes"
  verify_no_private_material

  while IFS= read -r -d '' f; do
    shown="$(log_path "$f")"
    mode="$(git -C "$root" ls-files -s -- "$f" | awk 'NR==1 { print $1 }')"
    case "$f" in
      env/enc/dev.env.enc|env/enc/prod.env.enc)
        [ "$mode" != "120000" ] || fail "approved ciphertext path is a tracked symlink: $shown"
        ;;
      env/enc/stage.env.enc)
        [ "$stage_enabled" -eq 1 ] || fail "tracked stage ciphertext exists without an exact stage rule: $shown"
        [ "$mode" != "120000" ] || fail "approved ciphertext path is a tracked symlink: $shown"
        ;;
      env/enc/*) fail "unexpected tracked file under env/enc: $shown" ;;
      .sops.yaml|.gitignore|.gitattributes|.env.example)
        [ "$mode" != "120000" ] || fail "policy file is a tracked symlink: $shown"
        ;;
      *)
        if is_plaintext_env_path "$f"; then
          fail "tracked plaintext dotenv path found: $shown"
        fi
        ;;
    esac
  done < <(git -C "$root" ls-files -z)

  if [ -e "$root/.env" ] || [ -L "$root/.env" ]; then
    [ -L "$root/.env" ] || fail "root .env exists but is not a symlink"
    target="$(readlink "$root/.env")"
    case "$target" in
      env/dec/dev.env|env/dec/prod.env) ;;
      env/dec/stage.env)
        [ "$stage_enabled" -eq 1 ] || fail "root .env selects stage without an exact stage rule"
        ;;
      *) fail "root .env points outside managed env/dec targets: $target" ;;
    esac
  fi

  if [ -d "$root/env/dec" ]; then
    mode="$(stat -c '%a' "$root/env/dec" 2>/dev/null || stat -f '%Lp' "$root/env/dec")"
    [ "$mode" = "700" ] || fail "$root/env/dec must be mode 0700 (found $mode)"
  fi

  while IFS= read -r name; do
    file="$(dec_path "$name")"
    assert_managed_file_safe "$file"
    if [ -f "$file" ]; then
      validate_dotenv_file "$file"
      mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")"
      [ "$mode" = "600" ] || fail "$file must be mode 0600 (found $mode)"
    fi
    file="$(enc_path "$name")"
    verify_ciphertext_file "$file"
    if [ -f "$file" ] && [ "${ORES_SOPS_VERIFY_DECRYPT:-0}" = "1" ]; then
      sops decrypt "${DOTENV[@]}" "$file" >/dev/null || fail "authorized decrypt failed for $name"
    fi
  done < <(managed_envs)

  printf 'ores-sops: policy verification passed\n'
}''',
)

init_replacement = r'''add_init_recipient() {
  local variable_name="$1" recipient="$2" current
  printf '%s' "$recipient" | grep -qE '^age1[a-z0-9]{58}$' \
    || fail "not an age public key: $recipient"
  current="${!variable_name:-}"
  case " $current " in *" $recipient "*) return 0 ;; esac
  if [ -n "$current" ]; then
    printf -v "$variable_name" '%s %s' "$current" "$recipient"
  else
    printf -v "$variable_name" '%s' "$recipient"
  fi
}

add_recipient_words() {
  local variable_name="$1" words="$2" recipient
  for recipient in $(printf '%s' "$words" | tr ',' ' '); do
    [ -n "$recipient" ] || continue
    add_init_recipient "$variable_name" "$recipient"
  done
}

recipient_block() {
  local variable_name="$1" recipient
  for recipient in ${!variable_name:-}; do
    printf '      - %s\n' "$recipient"
  done
}

cmd_init() {
  local root key local_recipient ignore attrs
  local with_stage=0 local_scope=all
  local all_raw="${ORES_SOPS_EXTRA_RECIPIENTS:-}"
  local dev_raw="${ORES_SOPS_DEV_RECIPIENTS:-}"
  local stage_raw="${ORES_SOPS_STAGE_RECIPIENTS:-}"
  local prod_raw="${ORES_SOPS_PROD_RECIPIENTS:-}"
  local recovery_raw="${ORES_SOPS_RECOVERY_RECIPIENTS:-}"
  local INIT_DEV_RECIPIENTS="" INIT_STAGE_RECIPIENTS="" INIT_PROD_RECIPIENTS=""
  local dev_block stage_block prod_block stage_enabled=0

  root="$(repo_root)"
  assert_policy_path_safe
  prepare_managed_tree

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --with-stage) with_stage=1; shift ;;
      --recipient)
        [ "$#" -ge 2 ] || fail "--recipient needs an age public key"
        all_raw="$all_raw $2"; shift 2 ;;
      --recipient=*) all_raw="$all_raw ${1#--recipient=}"; shift ;;
      --dev-recipient)
        [ "$#" -ge 2 ] || fail "--dev-recipient needs an age public key"
        dev_raw="$dev_raw $2"; shift 2 ;;
      --dev-recipient=*) dev_raw="$dev_raw ${1#--dev-recipient=}"; shift ;;
      --stage-recipient)
        [ "$#" -ge 2 ] || fail "--stage-recipient needs an age public key"
        stage_raw="$stage_raw $2"; shift 2 ;;
      --stage-recipient=*) stage_raw="$stage_raw ${1#--stage-recipient=}"; shift ;;
      --prod-recipient)
        [ "$#" -ge 2 ] || fail "--prod-recipient needs an age public key"
        prod_raw="$prod_raw $2"; shift 2 ;;
      --prod-recipient=*) prod_raw="$prod_raw ${1#--prod-recipient=}"; shift ;;
      --recovery-recipient)
        [ "$#" -ge 2 ] || fail "--recovery-recipient needs an age public key"
        recovery_raw="$recovery_raw $2"; shift 2 ;;
      --recovery-recipient=*) recovery_raw="$recovery_raw ${1#--recovery-recipient=}"; shift ;;
      --local-scope)
        [ "$#" -ge 2 ] || fail "--local-scope needs dev, stage, prod, dev-stage, or all"
        local_scope="$2"; shift 2 ;;
      --local-scope=*) local_scope="${1#--local-scope=}"; shift ;;
      *) fail "unknown argument for init: $1" ;;
    esac
  done

  case "$local_scope" in
    dev|stage|prod|dev-stage|all) ;;
    *) fail "--local-scope must be dev, stage, prod, dev-stage, or all" ;;
  esac
  if [ "$with_stage" -eq 0 ]; then
    case "$local_scope" in stage|dev-stage) fail "$local_scope local scope requires --with-stage" ;; esac
    [ -z "$stage_raw" ] || fail "--stage-recipient requires --with-stage"
  fi

  key="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
  [ -f "$key" ] || fail "no age identity at $key — create one with: age-keygen -o $key"
  local_recipient="$(grep -o 'age1[a-z0-9]\{58\}' "$key" | head -1)"
  [ -n "$local_recipient" ] || fail "no age recipient found in $key"

  case "$local_scope" in
    dev) add_init_recipient INIT_DEV_RECIPIENTS "$local_recipient" ;;
    stage) add_init_recipient INIT_STAGE_RECIPIENTS "$local_recipient" ;;
    prod) add_init_recipient INIT_PROD_RECIPIENTS "$local_recipient" ;;
    dev-stage)
      add_init_recipient INIT_DEV_RECIPIENTS "$local_recipient"
      add_init_recipient INIT_STAGE_RECIPIENTS "$local_recipient"
      ;;
    all)
      add_init_recipient INIT_DEV_RECIPIENTS "$local_recipient"
      [ "$with_stage" -eq 0 ] || add_init_recipient INIT_STAGE_RECIPIENTS "$local_recipient"
      add_init_recipient INIT_PROD_RECIPIENTS "$local_recipient"
      ;;
  esac

  add_recipient_words INIT_DEV_RECIPIENTS "$all_raw $dev_raw $recovery_raw"
  add_recipient_words INIT_PROD_RECIPIENTS "$all_raw $prod_raw $recovery_raw"
  if [ "$with_stage" -eq 1 ]; then
    add_recipient_words INIT_STAGE_RECIPIENTS "$all_raw $stage_raw $recovery_raw"
  fi

  [ -n "$INIT_DEV_RECIPIENTS" ] || fail "dev recipient set would be empty"
  [ -n "$INIT_PROD_RECIPIENTS" ] || fail "prod recipient set would be empty"
  if [ "$with_stage" -eq 1 ]; then
    [ -n "$INIT_STAGE_RECIPIENTS" ] || fail "stage recipient set would be empty"
  fi

  dev_block="$(recipient_block INIT_DEV_RECIPIENTS)"
  prod_block="$(recipient_block INIT_PROD_RECIPIENTS)"
  [ "$with_stage" -eq 0 ] || stage_block="$(recipient_block INIT_STAGE_RECIPIENTS)"

  if [ ! -f "$root/.sops.yaml" ]; then
    cat >"$root/.sops.yaml" <<EOF_SOPS
# Bootstrap policy. Dev, optional stage, and prod use separate exact path rules.
# The default local recipient scope is `all` for backward-compatible recovery.
# Prefer scoped human/workload recipients and run the access audit before use.
creation_rules:
  - path_regex: ^env/enc/dev\\.env\\.enc\$
    age:
$dev_block
EOF_SOPS
    if [ "$with_stage" -eq 1 ]; then
      cat >>"$root/.sops.yaml" <<EOF_STAGE
  - path_regex: ^env/enc/stage\\.env\\.enc\$
    age:
$stage_block
EOF_STAGE
    fi
    cat >>"$root/.sops.yaml" <<EOF_PROD
  - path_regex: ^env/enc/prod\\.env\\.enc\$
    age:
$prod_block
EOF_PROD
  elif [ "$with_stage" -eq 1 ] && ! stage_rule_present; then
    cat >>"$root/.sops.yaml" <<EOF_STAGE_APPEND
  - path_regex: ^env/enc/stage\\.env\\.enc\$
    age:
$stage_block
EOF_STAGE_APPEND
  fi

  stage_rule_present && stage_enabled=1

  ignore="$root/.gitignore"
  if ! grep -qF '# BEGIN ores-sops dotenv policy' "$ignore" 2>/dev/null; then
    cat >>"$ignore" <<'EOF_IGNORE'

# BEGIN ores-sops dotenv policy
# Plaintext dotenv is local-only at every depth, including common suffix variants.
*.env
*/*.env
*/**/*.env
.env.*
*.env.*
!.env.example

# Decrypted material is never tracked.
/env/dec/

# Only approved exact ciphertext paths are trackable.
/env/enc/*
!/env/enc/dev.env.enc
!/env/enc/prod.env.enc
# END ores-sops dotenv policy
EOF_IGNORE
  elif ! grep -Fxq '*.env.*' "$ignore"; then
    printf '\n# ores-sops hardening: ignore common dotenv suffix variants.\n*.env.*\n!/env/enc/dev.env.enc\n!/env/enc/prod.env.enc\n' >>"$ignore"
  fi
  if [ "$stage_enabled" -eq 1 ] && ! grep -Fxq '!/env/enc/stage.env.enc' "$ignore"; then
    printf '\n# ores-sops v0.4 optional exact stage ciphertext.\n!/env/enc/stage.env.enc\n' >>"$ignore"
  fi

  attrs="$root/.gitattributes"
  if ! grep -qF '/env/enc/*.env.enc text eol=lf' "$attrs" 2>/dev/null; then
    printf '\n/env/enc/*.env.enc text eol=lf\n' >>"$attrs"
  fi

  if [ ! -f "$root/.env.example" ]; then
    cat >"$root/.env.example" <<'EOF_EXAMPLE'
# Safe schema/example only. Never put real credentials here.
# REQUIRED_KEY=replace-with-obviously-fake-value
EOF_EXAMPLE
  fi

  cmd_verify
}'''
text = replace_function(text, "cmd_init", "usage", init_replacement)

sync_function = r'''cmd_sync_keys() {
  local name="${1:-}" path
  need_env "$name"
  path="$(enc_path "$name")"
  assert_managed_tree_safe
  assert_managed_file_safe "$path"
  [ -f "$path" ] || fail "missing env/enc/$name.env.enc"
  if [ "$name" = stage ] && ! stage_rule_present; then
    fail "stage key sync requires an exact stage SOPS creation rule"
  fi
  sops updatekeys -y --input-type dotenv "$path"
  if command -v ores-sops-access-audit >/dev/null 2>&1; then
    ores-sops-access-audit check
  fi
  printf 'ores-sops: synchronized recipients -> env/enc/%s.env.enc\n' "$name"
}

'''
text = replace_once(text, "cmd_edit() {", sync_function + "cmd_edit() {", "sync-keys insertion")

usage_replacement = r'''usage() {
  cat <<'EOF_USAGE'
ores-sops — ORESoftware SOPS dotenv convention

  init [options]          scaffold exact dev/prod policy, optionally stage
    --with-stage          add exact stage rule and Git allowlist
    --recipient K         add a legacy/shared recipient to every configured env
    --dev-recipient K     add a dev-only recipient
    --stage-recipient K   add a stage-only recipient (requires --with-stage)
    --prod-recipient K    add a prod-only recipient
    --recovery-recipient K add a recipient to every configured env
    --local-scope S       scope the local identity: dev|stage|prod|dev-stage|all
  use dev|stage|prod [-f] atomically decrypt and point .env at it
  encrypt dev|stage|prod  encrypt managed plaintext back to .env.enc
  sync-keys ENV           apply the exact .sops.yaml recipient set with updatekeys
  edit dev|stage|prod     edit ciphertext through SOPS
  diff dev|stage|prod     report changed key names only; never print values
  status                  show non-secret local state
  refresh                 refresh active plaintext after ciphertext changes
  verify                  keyless policy checks; set ORES_SOPS_VERIFY_DECRYPT=1 for decrypt checks
  precommit               block plaintext and unexpected env/enc paths
  lock                    remove managed plaintext, temp state, and managed .env symlink
  install-hooks           install safe refresh/pre-commit hooks
  ensure-dec              create the ignored runtime env/dec directory, mode 0700

Tracked secret-bearing paths are:
  env/enc/dev.env.enc
  env/enc/stage.env.enc   (optional; requires exact stage rule)
  env/enc/prod.env.enc

Every SOPS operation uses explicit --input-type dotenv --output-type dotenv.
Managed env/policy paths and hook files must not be symlinks.
Custom core.hooksPath is refused unless explicitly opted in after review.
EOF_USAGE
}'''
text = replace_function(text, "usage", "main", usage_replacement)
text = replace_once(
    text,
    "init|use|encrypt|edit|diff|status|refresh|verify|precommit|lock|install-hooks|ensure-dec)",
    "init|use|encrypt|sync-keys|edit|diff|status|refresh|verify|precommit|lock|install-hooks|ensure-dec)",
    "main prepare command list",
)
text = replace_once(
    text,
    "    encrypt) cmd_encrypt \"$@\" ;;\n    edit) cmd_edit \"$@\" ;;",
    "    encrypt) cmd_encrypt \"$@\" ;;\n    sync-keys) cmd_sync_keys \"$@\" ;;\n    edit) cmd_edit \"$@\" ;;",
    "main dispatch",
)
write(path, text)

path = "scripts/fleet-audit.sh"
text = read(path)
text = replace_once(
    text,
    "Provider states are none, dev, prod, or dev+prod.",
    "Provider states are none or a `+`-joined subset of dev, stage, and prod.",
    "fleet usage provider states",
)
text = replace_function(
    text,
    "sops_rule_state",
    "ignore_contract_state",
    r'''sops_rule_state() {
  local file="$1"
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

  awk '
    {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/^[[:space:]]*/, "", line)
    }
    line == "path_regex: ^env/enc/dev\\.env\\.enc$" { dev++; next }
    line == "path_regex: ^env/enc/stage\\.env\\.enc$" { stage++; next }
    line == "path_regex: ^env/enc/prod\\.env\\.enc$" { prod++; next }
    line ~ /^path_regex:/ && line ~ /env\/enc/ { broad = 1 }
    END {
      if (broad) print "broad"
      else if (dev != 1 || prod != 1 || stage > 1) print "missing"
      else if (stage == 1) print "exact-stage"
      else print "exact"
    }
  ' "$file"
}''',
)
text = replace_function(
    text,
    "ignore_contract_state",
    "attrs_state",
    r'''ignore_contract_state() {
  local stage_enabled=0
  [ -e .gitignore ] || { printf 'missing\n'; return; }
  is_tracked .gitignore || { printf 'untracked\n'; return; }
  [ -f .gitignore ] || { printf 'invalid\n'; return; }
  [ ! -L .gitignore ] || { printf 'invalid\n'; return; }

  if [ -f .sops.yaml ] && grep -Fq 'path_regex: ^env/enc/stage\.env\.enc$' .sops.yaml; then
    stage_enabled=1
  fi
  is_tracked env/enc/stage.env.enc && stage_enabled=1

  git check-ignore --no-index -q .env || { printf 'missing\n'; return; }
  git check-ignore --no-index -q sample.env || { printf 'missing\n'; return; }
  git check-ignore --no-index -q sample.env.local || { printf 'missing\n'; return; }
  git check-ignore --no-index -q env/dec/dev.env || { printf 'missing\n'; return; }
  git check-ignore --no-index -q env/dec/stage.env || { printf 'missing\n'; return; }
  git check-ignore --no-index -q env/dec/prod.env || { printf 'missing\n'; return; }
  if git check-ignore --no-index -q env/enc/dev.env.enc; then printf 'missing\n'; return; fi
  if git check-ignore --no-index -q env/enc/prod.env.enc; then printf 'missing\n'; return; fi
  if [ "$stage_enabled" -eq 1 ] && git check-ignore --no-index -q env/enc/stage.env.enc; then
    printf 'missing\n'
    return
  fi
  printf 'ok\n'
}''',
)
text = replace_function(
    text,
    "provider_env_state",
    "audit_one",
    r'''provider_env_state() {
  local pattern="$1"
  local environment file joined=""

  for environment in dev stage prod; do
    file="env/enc/${environment}.env.enc"
    if ! is_tracked "$file" || [ "$(tracked_mode "$file")" = 120000 ]; then
      continue
    fi

    if git show ":$file" 2>/dev/null | awk -F= -v pattern="$pattern" '
      /^[A-Za-z_][A-Za-z0-9_]*=/ {
        if ($1 ~ pattern) found = 1
      }
      END { exit(found ? 0 : 1) }
    '; then
      if [ -n "$joined" ]; then joined="$joined+$environment"; else joined="$environment"; fi
    fi
  done

  [ -n "$joined" ] && printf '%s\n' "$joined" || printf 'none\n'
}''',
)
text = replace_once(
    text,
    '''  local plaintext=0 unexpected=0 symlinks=0 env_enc_count=0 signals=0
  local tracked_env_dec=0 unguarded_mkdir=0
  local f mode rules ignore attrs status sendgrid_envs twilio_envs dockerignore''',
    '''  local plaintext=0 unexpected=0 symlinks=0 env_enc_count=0 signals=0
  local tracked_env_dec=0 unguarded_mkdir=0 stage_allowed=0
  local f mode rules ignore attrs status sendgrid_envs twilio_envs dockerignore''',
    "fleet audit locals",
)
text = replace_once(
    text,
    '''    while IFS= read -r -d '' f; do
      mode="$(tracked_mode "$f")"
      case "$f" in
        env/enc/dev.env.enc|env/enc/prod.env.enc)
          env_enc_count=$((env_enc_count + 1))
          [ "$mode" != 120000 ] || symlinks=$((symlinks + 1))
          ;;
        env/enc/*)''',
    '''    if [ -f .sops.yaml ] && grep -Fq 'path_regex: ^env/enc/stage\.env\.enc$' .sops.yaml; then
      stage_allowed=1
    fi

    while IFS= read -r -d '' f; do
      mode="$(tracked_mode "$f")"
      case "$f" in
        env/enc/dev.env.enc|env/enc/prod.env.enc)
          env_enc_count=$((env_enc_count + 1))
          [ "$mode" != 120000 ] || symlinks=$((symlinks + 1))
          ;;
        env/enc/stage.env.enc)
          env_enc_count=$((env_enc_count + 1))
          [ "$stage_allowed" -eq 1 ] || unexpected=$((unexpected + 1))
          [ "$mode" != 120000 ] || symlinks=$((symlinks + 1))
          ;;
        env/enc/*)''',
    "fleet stage tracked path",
)
text = replace_once(
    text,
    '    elif [ "$rules" = exact ] && [ "$ignore" = ok ] && [ "$attrs" = ok ]; then',
    '    elif { [ "$rules" = exact ] || [ "$rules" = exact-stage ]; } && [ "$ignore" = ok ] && [ "$attrs" = ok ]; then',
    "fleet adopted state",
)
write(path, text)

path = "README.md"
text = read(path)
replacements = [
    ("Exact `dev`/`prod` SOPS dotenv contract", "Exact `dev`/optional `stage`/`prod` SOPS dotenv contract"),
    ("Exactly two secret-bearing ciphertext files are allowed in version control:", "Two ciphertext files are required and one exact stage ciphertext is optional:"),
    ("env/enc/dev.env.enc\nenv/enc/prod.env.enc", "env/enc/dev.env.enc\nenv/enc/stage.env.enc   # optional\nenv/enc/prod.env.enc"),
    ("env/dec/dev.env\nenv/dec/prod.env\n.env -> env/dec/dev.env   # or prod", "env/dec/dev.env\nenv/dec/stage.env       # optional\nenv/dec/prod.env\n.env -> env/dec/dev.env   # or stage or prod"),
    ("--filename-override env/enc/<dev|prod>.env.enc", "--filename-override env/enc/<dev|stage|prod>.env.enc"),
    ("# Only the two approved ciphertext files are trackable.", "# Only approved exact ciphertext files are trackable."),
    ("!/env/enc/dev.env.enc\n!/env/enc/prod.env.enc", "!/env/enc/dev.env.enc\n!/env/enc/stage.env.enc\n!/env/enc/prod.env.enc"),
    ("ores-sops use dev|prod [--force]", "ores-sops use dev|stage|prod [--force]"),
    ("ores-sops encrypt dev|prod [--allow-empty]", "ores-sops encrypt dev|stage|prod [--allow-empty]"),
    ("ores-sops edit dev|prod", "ores-sops edit dev|stage|prod"),
    ("ores-sops diff dev|prod", "ores-sops diff dev|stage|prod"),
    ("Arbitrary environment names are rejected. This is intentional: the tracked VCS contract is exactly `dev` and `prod`.", "Arbitrary environment names are rejected. The tracked VCS contract is exactly required `dev`/`prod` plus one optional exact `stage` environment."),
    ("into `env/dec/dev.env` or `env/dec/prod.env`.", "into `env/dec/dev.env`, optional `env/dec/stage.env`, or `env/dec/prod.env`."),
    ("`init` creates separate exact creation rules for dev and prod.", "`init` creates separate exact creation rules for dev and prod; `init --with-stage` adds the optional exact stage rule."),
    ("keep dev and prod recipient sets separate;", "keep dev, stage, and prod recipient sets least-privilege and environment-scoped;"),
    ("exact dev/prod SOPS path rules and no broad env/enc rules;", "exact dev/prod SOPS path rules, optional exact stage rule, and no broad env/enc rules;"),
    ("any tracked `env/enc/*` path other than `dev.env.enc` and `prod.env.enc`;", "any tracked `env/enc/*` path other than exact dev/prod and an explicitly configured exact stage ciphertext;"),
    ("dev/prod name restriction", "dev/optional-stage/prod name restriction"),
    ("generated dev/prod/recovery lifecycle", "generated dev/stage/prod/recovery lifecycle and negative decrypt matrix"),
]
for old, new in replacements:
    if old not in text:
        raise SystemExit(f"README replacement missing: {old!r}")
    text = text.replace(old, new)
text = text.replace(
    "ores-sops init\n\nores-sops use dev|stage|prod",
    "ores-sops init [--with-stage] [scoped recipient options]\n\nores-sops use dev|stage|prod",
)
text = text.replace(
    "ores-sops encrypt dev|stage|prod [--allow-empty]\n",
    "ores-sops encrypt dev|stage|prod [--allow-empty]\nores-sops sync-keys dev|stage|prod\n",
)
write(path, text)

path = "docs/access-control.md"
write(
    path,
    r'''# Environment-scoped SOPS + age access control

## Decision

An age public recipient must **not** automatically appear on every encrypted
environment file. Access is granted per ciphertext file by listing only the
approved recipients on that file's exact SOPS creation rule.

The v0.4 contract uses required development and production files plus one
optional, exact staging environment:

```text
env/enc/dev.env.enc
env/enc/stage.env.enc   # optional exact-rule opt-in
env/enc/prod.env.enc

# Runtime-only plaintext
env/dec/dev.env
env/dec/stage.env
env/dec/prod.env
```

A developer who is listed only on the dev rule can clone every ciphertext but
can decrypt only `dev.env.enc`. A stage-only identity cannot decrypt prod. A
shared recovery identity can decrypt multiple environments only because it is
explicitly listed on each of those rules.

## Recommended access matrix

| Identity class | dev | stage | prod | Notes |
| --- | ---: | ---: | ---: | --- |
| ordinary developer | yes | no | no | Individual human identity |
| release engineer | yes | yes | no | May promote to stage, not prod |
| production-authorized developer | yes | yes | yes | Explicit elevated mapping |
| dev CI workload | yes | no | no | Never expose to fork PRs |
| stage deploy workload | no | yes | no | Stage-only workload identity |
| prod deploy workload | no | no | yes | Prefer OIDC-backed KMS/workload identity |
| break-glass recovery | yes | yes | yes | Offline and independently controlled |

The same person may use one age identity on several approved files, but a
separate hardware-backed production identity reduces blast radius.

## How the cryptographic boundary works

Each SOPS file has its own random data-encryption key. SOPS encrypts the values
with that per-file key and wraps the key separately for every configured age
recipient or master key. A normal `age:` list is one-of-many: any listed private
identity can unwrap that file key. Being listed on one environment does not grant
access to another.

Public `age1...` recipients are safe to commit. Private `AGE-SECRET-KEY-...`
identities must remain on the developer device, hardware token, secret manager,
or protected workload and must never enter Git, issues, pull requests, logs,
artifacts, caches, screenshots, or chat.

## Canonical `.sops.yaml` pattern

Replace placeholders with real public recipients:

```yaml
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1_DEV_ALICE_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RELEASE_ENGINEER_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT

  - path_regex: ^env/enc/stage\.env\.enc$
    age:
      - age1_RELEASE_ENGINEER_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_STAGE_DEPLOY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT

  - path_regex: ^env/enc/prod\.env\.enc$
    age:
      - age1_PROD_OPERATOR_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_PROD_DEPLOY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
```

This matrix gives Alice only dev, the release engineer dev+stage, production
operators only the environments on which they are listed, and recovery all three.

## Scaffolding

Backward-compatible two-environment bootstrap:

```sh
ores-sops init
```

Three-environment scaffold with scoped recipients:

```sh
ores-sops init --with-stage \
  --local-scope dev \
  --dev-recipient age1... \
  --stage-recipient age1... \
  --prod-recipient age1... \
  --recovery-recipient age1...
```

`--recipient` remains the legacy/shared option and adds its recipient to every
configured environment. Prefer the scoped flags for new repositories.

## Desired policy versus actual ciphertext

`.sops.yaml` is desired state. Existing ciphertext retains its current wrapped
recipient metadata until the affected file is updated. Editing policy alone does
not grant or revoke access.

Apply a change to only the affected file:

```sh
ores-sops sync-keys dev
ores-sops sync-keys stage
ores-sops sync-keys prod

# Equivalent low-level command:
sops updatekeys -y --input-type dotenv env/enc/stage.env.enc
```

Then require exact desired-versus-actual agreement:

```sh
ores-sops verify
ores-sops-access-audit check --require-ciphertext
```

The access audit never decrypts. It reads `.sops.yaml` and only public
`sops_age__list_*__map_recipient` metadata from existing ciphertext. Normal
output reports counts, not recipient values.

With stage enabled, the audit requires:

- at least one dev-only recipient omitted from both stage and prod;
- at least one stage recipient omitted from prod;
- the configured recipient set on every ciphertext to match its exact rule;
- an optional production-only identity when `--require-prod-exclusive` is used.

## Onboarding

1. Generate an individual age identity locally or obtain an approved
   hardware-backed identity.
2. Supply only the public `age1...` recipient.
3. Add it to exactly the allowed environment rule or rules.
4. Review `.sops.yaml` and protected ciphertext changes under CODEOWNERS.
5. Run `ores-sops sync-keys <environment>` for each affected file.
6. Run the required-ciphertext access audit and normal verification.
7. Test positive and negative decryptability in a trusted environment without
   printing values.

## Offboarding and compromise

1. Remove the public recipient from every environment being revoked.
2. Run `ores-sops sync-keys <environment>` for each affected current ciphertext.
3. Prove the removed identity fails to decrypt those current files.
4. Rotate the SOPS data key when warranted:

```sh
sops --rotate --in-place \
  --input-type dotenv \
  --output-type dotenv \
  env/enc/prod.env.enc
```

5. Rotate application credentials whenever the person may have learned them.
6. Remove GitHub, CI, cloud, shell, VPN, and secret-manager access separately.

Old Git commits may remain decryptable to identities authorized for those old
revisions. Repository history is not a revocation system.

## Stronger production approval

A plain age list is OR authorization. SOPS `key_groups` with a Shamir threshold
can require multiple trust domains, such as an approved human group and a cloud
KMS/workload group. That is a separate availability and recovery policy. The
age-list access audit fails closed on `key_groups` rather than pretending it has
validated a threshold configuration.

## Nix, Just, GitHub, and sops-nix responsibilities

- **SOPS + age** decides who can decrypt each tracked file.
- **Nix** pins tool versions; it does not grant access.
- **Just** supplies reviewed recipes; it does not bypass cryptography.
- **GitHub permissions** control who can clone or modify ciphertext, not who can
  decrypt it.
- **CODEOWNERS and branch protection** should protect `.sops.yaml`, stage/prod
  ciphertext, and trusted deployment workflows.
- **sops-nix owner/group/mode** controls local plaintext access after a host has
  decrypted a secret; it is separate from the repository recipient matrix.
''',
)

path = "examples/access-control/.sops.yaml.example"
write(
    path,
    r'''# Copy to .sops.yaml and replace placeholders with real PUBLIC age1...
# recipients. Never place an AGE-SECRET-KEY identity in this file or in Git.
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1_DEV_DEVELOPER_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RELEASE_ENGINEER_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT

  - path_regex: ^env/enc/stage\.env\.enc$
    age:
      - age1_RELEASE_ENGINEER_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_STAGE_DEPLOY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT

  - path_regex: ^env/enc/prod\.env\.enc$
    age:
      - age1_PROD_OPERATOR_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_PROD_DEPLOY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
      - age1_RECOVERY_REPLACE_WITH_REAL_PUBLIC_RECIPIENT
''',
)

path = "examples/access-control/Justfile"
text = read(path)
text = text.replace("dev|prod", "dev|stage|prod")
text = text.replace("expected dev or prod", "expected dev, stage, or prod")
write(path, text)

path = "AGENTS.md"
text = read(path)
text = text.replace(
    "Before production reliance, at least one ordinary development recipient must be omitted from prod; shared recovery and production-authorized developers may be explicit on both.",
    "With stage configured, at least one ordinary development recipient must be omitted from both stage and prod, and at least one stage recipient must be omitted from prod; shared recovery and elevated recipients remain explicit.",
)
text = text.replace(
    "The v0.3 contract is exactly dev/prod. Do not add stage or another `env/enc` path without a versioned helper, policy, and test rollout.",
    "The v0.4 contract is exact dev/prod plus one optional exact stage environment; reject every other `env/enc` path.",
)
write(path, text)

path = ".github/CODEOWNERS"
text = read(path)
if "/env/enc/stage.env.enc @ORESoftware\n" not in text:
    text = text.replace(
        "/env/enc/prod.env.enc @ORESoftware\n",
        "/env/enc/stage.env.enc @ORESoftware\n/env/enc/prod.env.enc @ORESoftware\n",
    )
write(path, text)

path = "docs/fleet-audit.md"
text = read(path)
text = text.replace(
    "tracked exact dev/prod SOPS rules",
    "tracked exact dev/prod SOPS rules with an optional exact stage rule",
)
text = text.replace(
    "Provider states are `none`, `dev`, `prod`, or `dev+prod`.",
    "Provider states are `none` or a `+`-joined subset of `dev`, `stage`, and `prod`.",
)
write(path, text)
