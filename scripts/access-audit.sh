#!/usr/bin/env bash
# Keyless audit for the canonical ORESoftware dev/(optional stage)/prod age recipient matrix.
# Public age recipients may be printed only by the explicit `show` command.

set -euo pipefail

VERSION="0.2.0"
POLICY=".sops.yaml"
MIN_RECIPIENTS=2
REQUIRE_PROD_EXCLUSIVE=0
POLICY_ONLY=0
REQUIRE_CIPHERTEXT=0

fail() {
  printf 'ores-sops-access-audit: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF_USAGE'
ores-sops-access-audit — verify least-privilege age recipients without decrypting

Usage:
  ores-sops-access-audit check [--policy PATH] [--min-recipients N]
                                  [--require-prod-exclusive]
                                  [--policy-only | --require-ciphertext]
  ores-sops-access-audit show  [--policy PATH]
  ores-sops-access-audit --version

`check` requires exact dev and prod rules and permits one optional exact stage
rule. When stage is configured, at least one dev recipient must be omitted from
both stage and prod, and at least one stage recipient must be omitted from prod.
Production-authorized people may still be listed on lower environments. Use
`--require-prod-exclusive` when policy also requires a production-only identity.
Shared recovery recipients are allowed. The default minimum is two recipients
per configured environment so one lost identity is not permanent data loss.

When ciphertext files exist, `check` also compares their public SOPS age
recipient metadata with `.sops.yaml`; this catches a policy edit that has not
been applied with `sops updatekeys`. `--require-ciphertext` requires every
configured ciphertext file, while `--policy-only` explicitly skips that check.

`show` emits the desired public recipient matrix as TSV. No command decrypts or
reads private identities, application assignments, or encrypted values. Only
exact dev, optional stage, and prod env/enc rules are accepted.
EOF_USAGE
}

trim_line() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

contains_line() {
  local list="$1" value="$2"
  case $'\n'"$list"$'\n' in
    *$'\n'"$value"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

get_desired() {
  case "$1" in
    dev) printf '%s' "$DEV_RECIPIENTS" ;;
    stage) printf '%s' "$STAGE_RECIPIENTS" ;;
    prod) printf '%s' "$PROD_RECIPIENTS" ;;
    *) fail "internal parser error for environment '$1'" ;;
  esac
}

set_desired() {
  case "$1" in
    dev) DEV_RECIPIENTS="$2" ;;
    stage) STAGE_RECIPIENTS="$2" ;;
    prod) PROD_RECIPIENTS="$2" ;;
    *) fail "internal parser error for environment '$1'" ;;
  esac
}

get_actual() {
  case "$1" in
    dev) printf '%s' "$ACTUAL_DEV_RECIPIENTS" ;;
    stage) printf '%s' "$ACTUAL_STAGE_RECIPIENTS" ;;
    prod) printf '%s' "$ACTUAL_PROD_RECIPIENTS" ;;
    *) fail "internal ciphertext parser error for environment '$1'" ;;
  esac
}

set_actual() {
  case "$1" in
    dev) ACTUAL_DEV_RECIPIENTS="$2" ;;
    stage) ACTUAL_STAGE_RECIPIENTS="$2" ;;
    prod) ACTUAL_PROD_RECIPIENTS="$2" ;;
    *) fail "internal ciphertext parser error for environment '$1'" ;;
  esac
}

append_recipient() {
  local environment="$1" recipient="$2" current
  printf '%s' "$recipient" | grep -qE '^age1[a-z0-9]{58}$' \
    || fail "malformed public age recipient in the $environment rule"

  current="$(get_desired "$environment")"
  contains_line "$current" "$recipient" \
    && fail "duplicate public age recipient in the $environment rule"

  if [ -n "$current" ]; then
    current="$current"$'\n'"$recipient"
  else
    current="$recipient"
  fi
  set_desired "$environment" "$current"
}

parse_policy() {
  local line trimmed current="" section=""

  [ -f "$POLICY" ] || fail "missing policy file: $POLICY"
  [ ! -L "$POLICY" ] || fail "policy file must not be a symlink: $POLICY"

  DEV_RECIPIENTS=""
  STAGE_RECIPIENTS=""
  PROD_RECIPIENTS=""
  DEV_RULES=0
  STAGE_RULES=0
  PROD_RULES=0

  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="$(trim_line "$line")"
    case "$trimmed" in
      ''|'#'*) continue ;;
      '- path_regex: ^env/enc/dev\.env\.enc$')
        DEV_RULES=$((DEV_RULES + 1))
        current="dev"
        section=""
        ;;
      '- path_regex: ^env/enc/stage\.env\.enc$')
        STAGE_RULES=$((STAGE_RULES + 1))
        current="stage"
        section=""
        ;;
      '- path_regex: ^env/enc/prod\.env\.enc$')
        PROD_RULES=$((PROD_RULES + 1))
        current="prod"
        section=""
        ;;
      '- path_regex:'*)
        case "$trimmed" in
          *env/enc*) fail "broad or noncanonical env/enc creation rule is not allowed" ;;
        esac
        current=""
        section=""
        ;;
      'key_groups:'|'- key_groups:')
        [ -z "$current" ] || fail "key_groups require a separate threshold-policy review; this audit is age-list only"
        section=""
        ;;
      'age:')
        if [ -n "$current" ]; then
          section="age"
        else
          section=""
        fi
        ;;
      '- age1'*)
        if [ "$section" = "age" ] && [ -n "$current" ]; then
          append_recipient "$current" "${trimmed#- }"
        fi
        ;;
      *':')
        section=""
        ;;
    esac
  done <"$POLICY"

  [ "$DEV_RULES" -eq 1 ] || fail "expected exactly one canonical dev creation rule"
  [ "$PROD_RULES" -eq 1 ] || fail "expected exactly one canonical prod creation rule"
  [ "$STAGE_RULES" -le 1 ] || fail "expected at most one canonical stage creation rule"
}

configured_envs() {
  printf 'dev\n'
  [ "$STAGE_RULES" -eq 1 ] && printf 'stage\n'
  printf 'prod\n'
}

append_actual_recipient() {
  local environment="$1" recipient="$2" current
  printf '%s' "$recipient" | grep -qE '^age1[a-z0-9]{58}$' \
    || fail "malformed public age recipient metadata in $environment ciphertext"

  current="$(get_actual "$environment")"
  contains_line "$current" "$recipient" \
    && fail "duplicate public age recipient metadata in $environment ciphertext"

  if [ -n "$current" ]; then
    current="$current"$'\n'"$recipient"
  else
    current="$recipient"
  fi
  set_actual "$environment" "$current"
}

parse_ciphertext_recipients() {
  local environment="$1" path="$2" line key recipient actual

  [ ! -L "$path" ] || fail "$environment ciphertext must not be a symlink: $path"
  [ -f "$path" ] || fail "missing $environment ciphertext: $path"
  set_actual "$environment" ""

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      sops_age__list_*__map_recipient=*)
        key="${line%%=*}"
        printf '%s' "$key" | grep -qE '^sops_age__list_[0-9]+__map_recipient$' \
          || fail "malformed SOPS age recipient metadata key in $environment ciphertext"
        recipient="${line#*=}"
        append_actual_recipient "$environment" "$recipient"
        ;;
    esac
  done <"$path"

  actual="$(get_actual "$environment")"
  [ -n "$actual" ] || fail "$environment ciphertext has no readable public age recipient metadata"
}

count_lines() {
  local list="$1"
  if [ -z "$list" ]; then
    printf '0\n'
  else
    printf '%s\n' "$list" | wc -l | tr -d '[:space:]'
    printf '\n'
  fi
}

count_exclusive() {
  local left="$1" right="$2" recipient count=0
  while IFS= read -r recipient || [ -n "$recipient" ]; do
    [ -n "$recipient" ] || continue
    if ! contains_line "$right" "$recipient"; then
      count=$((count + 1))
    fi
  done <<<"$left"
  printf '%s\n' "$count"
}

count_exclusive_from_two() {
  local left="$1" right_a="$2" right_b="$3" recipient count=0
  while IFS= read -r recipient || [ -n "$recipient" ]; do
    [ -n "$recipient" ] || continue
    if ! contains_line "$right_a" "$recipient" && ! contains_line "$right_b" "$recipient"; then
      count=$((count + 1))
    fi
  done <<<"$left"
  printf '%s\n' "$count"
}

count_shared() {
  local left="$1" right="$2" recipient count=0
  while IFS= read -r recipient || [ -n "$recipient" ]; do
    [ -n "$recipient" ] || continue
    if contains_line "$right" "$recipient"; then
      count=$((count + 1))
    fi
  done <<<"$left"
  printf '%s\n' "$count"
}

count_shared_three() {
  local left="$1" middle="$2" right="$3" recipient count=0
  while IFS= read -r recipient || [ -n "$recipient" ]; do
    [ -n "$recipient" ] || continue
    if contains_line "$middle" "$recipient" && contains_line "$right" "$recipient"; then
      count=$((count + 1))
    fi
  done <<<"$left"
  printf '%s\n' "$count"
}

sets_equal() {
  local left="$1" right="$2" recipient
  [ "$(count_lines "$left")" = "$(count_lines "$right")" ] || return 1
  while IFS= read -r recipient || [ -n "$recipient" ]; do
    [ -n "$recipient" ] || continue
    contains_line "$right" "$recipient" || return 1
  done <<<"$left"
}

check_ciphertext_sync() {
  local environment path desired actual checked=0 expected=2

  if [ "$STAGE_RULES" -eq 0 ] && { [ -e env/enc/stage.env.enc ] || [ -L env/enc/stage.env.enc ]; }; then
    fail "stage ciphertext exists without an exact stage rule in .sops.yaml"
  fi
  [ "$STAGE_RULES" -eq 0 ] || expected=3

  while IFS= read -r environment; do
    path="env/enc/$environment.env.enc"
    if [ -e "$path" ] || [ -L "$path" ]; then
      parse_ciphertext_recipients "$environment" "$path"
      desired="$(get_desired "$environment")"
      actual="$(get_actual "$environment")"
      sets_equal "$desired" "$actual" \
        || fail "$environment ciphertext recipients differ from .sops.yaml; run sops updatekeys for $path"
      checked=$((checked + 1))
    elif [ "$REQUIRE_CIPHERTEXT" -eq 1 ]; then
      fail "missing required ciphertext: $path"
    fi
  done < <(configured_envs)

  if [ "$REQUIRE_CIPHERTEXT" -eq 1 ] && [ "$checked" -ne "$expected" ]; then
    fail "expected every configured canonical ciphertext file"
  fi
  CHECKED_CIPHERTEXT="$checked"
}

cmd_check() {
  local dev_count stage_count prod_count dev_only stage_not_prod prod_only shared
  parse_policy

  dev_count="$(count_lines "$DEV_RECIPIENTS")"
  prod_count="$(count_lines "$PROD_RECIPIENTS")"
  [ "$dev_count" -ge "$MIN_RECIPIENTS" ] \
    || fail "dev has $dev_count recipient(s); require at least $MIN_RECIPIENTS"
  [ "$prod_count" -ge "$MIN_RECIPIENTS" ] \
    || fail "prod has $prod_count recipient(s); require at least $MIN_RECIPIENTS"

  if [ "$STAGE_RULES" -eq 1 ]; then
    stage_count="$(count_lines "$STAGE_RECIPIENTS")"
    [ "$stage_count" -ge "$MIN_RECIPIENTS" ] \
      || fail "stage has $stage_count recipient(s); require at least $MIN_RECIPIENTS"

    dev_only="$(count_exclusive_from_two "$DEV_RECIPIENTS" "$STAGE_RECIPIENTS" "$PROD_RECIPIENTS")"
    stage_not_prod="$(count_exclusive "$STAGE_RECIPIENTS" "$PROD_RECIPIENTS")"
    prod_only="$(count_exclusive_from_two "$PROD_RECIPIENTS" "$DEV_RECIPIENTS" "$STAGE_RECIPIENTS")"
    shared="$(count_shared_three "$DEV_RECIPIENTS" "$STAGE_RECIPIENTS" "$PROD_RECIPIENTS")"

    [ "$dev_only" -ge 1 ] \
      || fail "dev has no dev-only recipient; every dev recipient can decrypt stage or prod"
    [ "$stage_not_prod" -ge 1 ] \
      || fail "stage has no non-production recipient; every stage recipient can decrypt prod"
    if [ "$REQUIRE_PROD_EXCLUSIVE" -eq 1 ]; then
      [ "$prod_only" -ge 1 ] \
        || fail "prod has no environment-exclusive recipient; --require-prod-exclusive was requested"
    fi
  else
    stage_count=0
    stage_not_prod=0
    dev_only="$(count_exclusive "$DEV_RECIPIENTS" "$PROD_RECIPIENTS")"
    prod_only="$(count_exclusive "$PROD_RECIPIENTS" "$DEV_RECIPIENTS")"
    shared="$(count_shared "$DEV_RECIPIENTS" "$PROD_RECIPIENTS")"

    [ "$dev_only" -ge 1 ] \
      || fail "dev has no environment-exclusive recipient; every dev recipient can decrypt prod"
    if [ "$REQUIRE_PROD_EXCLUSIVE" -eq 1 ]; then
      [ "$prod_only" -ge 1 ] \
        || fail "prod has no environment-exclusive recipient; --require-prod-exclusive was requested"
    fi
  fi

  CHECKED_CIPHERTEXT=0
  if [ "$POLICY_ONLY" -eq 0 ]; then
    check_ciphertext_sync
  fi

  if [ "$STAGE_RULES" -eq 1 ]; then
    printf 'ores-sops-access-audit: passed (dev=%s, stage=%s, prod=%s, shared-all=%s, dev-only=%s, stage-not-prod=%s, prod-only=%s)\n' \
      "$dev_count" "$stage_count" "$prod_count" "$shared" "$dev_only" "$stage_not_prod" "$prod_only"
  else
    printf 'ores-sops-access-audit: passed (dev=%s, prod=%s, shared=%s, dev-only=%s, prod-only=%s)\n' \
      "$dev_count" "$prod_count" "$shared" "$dev_only" "$prod_only"
  fi
  if [ "$POLICY_ONLY" -eq 1 ]; then
    printf 'ores-sops-access-audit: ciphertext sync explicitly skipped (--policy-only)\n'
  else
    printf 'ores-sops-access-audit: ciphertext recipient metadata checked for %s file(s)\n' \
      "$CHECKED_CIPHERTEXT"
  fi
}

show_environment() {
  local environment="$1" list="$2" recipient
  while IFS= read -r recipient || [ -n "$recipient" ]; do
    [ -n "$recipient" ] || continue
    printf '%s\t%s\n' "$environment" "$recipient"
  done <<<"$list"
}

cmd_show() {
  parse_policy
  printf 'environment\tpublic_age_recipient\n'
  show_environment dev "$DEV_RECIPIENTS"
  if [ "$STAGE_RULES" -eq 1 ]; then
    show_environment stage "$STAGE_RECIPIENTS"
  fi
  show_environment prod "$PROD_RECIPIENTS"
}

main() {
  local command="${1:-check}"
  [ "$#" -gt 0 ] && shift || true

  case "$command" in
    --version|version)
      printf 'ores-sops-access-audit %s\n' "$VERSION"
      return 0
      ;;
    -h|--help|help)
      usage
      return 0
      ;;
    check|show) ;;
    *) fail "unknown command '$command' (try: ores-sops-access-audit help)" ;;
  esac

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --policy)
        [ "$#" -ge 2 ] || fail "--policy needs a path"
        POLICY="$2"
        shift 2
        ;;
      --policy=*)
        POLICY="${1#--policy=}"
        shift
        ;;
      --min-recipients)
        [ "$command" = "check" ] || fail "--min-recipients is valid only with check"
        [ "$#" -ge 2 ] || fail "--min-recipients needs a positive integer"
        MIN_RECIPIENTS="$2"
        shift 2
        ;;
      --min-recipients=*)
        [ "$command" = "check" ] || fail "--min-recipients is valid only with check"
        MIN_RECIPIENTS="${1#--min-recipients=}"
        shift
        ;;
      --require-prod-exclusive)
        [ "$command" = "check" ] || fail "--require-prod-exclusive is valid only with check"
        REQUIRE_PROD_EXCLUSIVE=1
        shift
        ;;
      --policy-only)
        [ "$command" = "check" ] || fail "--policy-only is valid only with check"
        POLICY_ONLY=1
        shift
        ;;
      --require-ciphertext)
        [ "$command" = "check" ] || fail "--require-ciphertext is valid only with check"
        REQUIRE_CIPHERTEXT=1
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *) fail "unknown argument '$1'" ;;
    esac
  done

  case "$MIN_RECIPIENTS" in
    ''|*[!0-9]*|0) fail "--min-recipients must be a positive integer" ;;
  esac
  if [ "$POLICY_ONLY" -eq 1 ] && [ "$REQUIRE_CIPHERTEXT" -eq 1 ]; then
    fail "--policy-only and --require-ciphertext are mutually exclusive"
  fi

  case "$command" in
    check) cmd_check ;;
    show) cmd_show ;;
  esac
}

main "$@"
