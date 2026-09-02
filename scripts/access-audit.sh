#!/usr/bin/env bash
# Keyless audit for the canonical ORESoftware dev/prod age recipient matrix.
# Public age recipients may be printed only by the explicit `show` command.

set -euo pipefail

VERSION="0.1.0"
POLICY=".sops.yaml"
MIN_RECIPIENTS=2
REQUIRE_PROD_EXCLUSIVE=0

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
  ores-sops-access-audit show  [--policy PATH]
  ores-sops-access-audit --version

`check` requires one exact dev rule and one exact prod rule, age recipient lists,
and at least one dev-only recipient so ordinary development access cannot unlock
production. Production recipients may also have development access. Use
`--require-prod-exclusive` when policy requires a distinct production-only
identity. Shared recovery recipients are allowed. The default minimum is two
recipients per environment so one lost identity is not permanent data loss.

`show` emits the public recipient matrix as TSV. It never reads ciphertext or
private identities. This release intentionally follows the current exact
`dev`/`prod` ores-sops contract; other env/enc rules fail closed.
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

append_recipient() {
  local environment="$1" recipient="$2" current
  printf '%s' "$recipient" | grep -qE '^age1[a-z0-9]{58}$' \
    || fail "malformed public age recipient in the $environment rule"

  case "$environment" in
    dev) current="$DEV_RECIPIENTS" ;;
    prod) current="$PROD_RECIPIENTS" ;;
    *) fail "internal parser error for environment '$environment'" ;;
  esac

  contains_line "$current" "$recipient" \
    && fail "duplicate public age recipient in the $environment rule"

  if [ -n "$current" ]; then
    current="$current"$'\n'"$recipient"
  else
    current="$recipient"
  fi

  case "$environment" in
    dev) DEV_RECIPIENTS="$current" ;;
    prod) PROD_RECIPIENTS="$current" ;;
  esac
}

parse_policy() {
  local line trimmed current="" section=""

  [ -f "$POLICY" ] || fail "missing policy file: $POLICY"
  [ ! -L "$POLICY" ] || fail "policy file must not be a symlink: $POLICY"

  DEV_RECIPIENTS=""
  PROD_RECIPIENTS=""
  DEV_RULES=0
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

cmd_check() {
  local dev_count prod_count dev_only prod_only shared
  parse_policy

  dev_count="$(count_lines "$DEV_RECIPIENTS")"
  prod_count="$(count_lines "$PROD_RECIPIENTS")"
  [ "$dev_count" -ge "$MIN_RECIPIENTS" ] \
    || fail "dev has $dev_count recipient(s); require at least $MIN_RECIPIENTS"
  [ "$prod_count" -ge "$MIN_RECIPIENTS" ] \
    || fail "prod has $prod_count recipient(s); require at least $MIN_RECIPIENTS"

  dev_only="$(count_exclusive "$DEV_RECIPIENTS" "$PROD_RECIPIENTS")"
  prod_only="$(count_exclusive "$PROD_RECIPIENTS" "$DEV_RECIPIENTS")"
  shared="$(count_shared "$DEV_RECIPIENTS" "$PROD_RECIPIENTS")"

  [ "$dev_only" -ge 1 ] \
    || fail "dev has no environment-exclusive recipient; every dev recipient can decrypt prod"
  if [ "$REQUIRE_PROD_EXCLUSIVE" -eq 1 ]; then
    [ "$prod_only" -ge 1 ] \
      || fail "prod has no environment-exclusive recipient; --require-prod-exclusive was requested"
  fi

  printf 'ores-sops-access-audit: passed (dev=%s, prod=%s, shared=%s, dev-only=%s, prod-only=%s)\n' \
    "$dev_count" "$prod_count" "$shared" "$dev_only" "$prod_only"
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

  case "$command" in
    check) cmd_check ;;
    show) cmd_show ;;
  esac
}

main "$@"
