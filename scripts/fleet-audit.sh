#!/usr/bin/env bash
# Path/policy-only fleet conformance scanner for the ORESoftware SOPS dotenv contract.
#
# The default scan deliberately never decrypts files and never reads application
# dotenv/ciphertext values. With --provider-inventory it reads only variable
# names from tracked SOPS dotenv blobs through the Git index; ciphertext values
# are never emitted. Reports contain only repository adoption state and
# non-secret policy metadata that are safe for rollout prioritization.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ores-sops-fleet-audit [--strict] [--provider-inventory] [--consumer-bypass] [repo-path ...]

Emit one TSV row per local Git repository with only non-secret conformance data.
When no repository path is supplied, audit the current repository.

Statuses:
  adopted       exact tracked SOPS rules + ignore contract + ciphertext attributes
  not-adopted   no SOPS dotenv adoption signal detected
  partial       some adoption signal exists but the contract is incomplete
  conflicting   tracked plaintext, unexpected env/enc path, symlink policy path,
                or broad/noncanonical env/enc SOPS rule was detected

--provider-inventory adds tracked_env_dec, sendgrid_envs, and twilio_envs columns.
Provider states are none or a `+`-joined subset of dev, stage, and prod. The scanner parses only the
variable name before '=' from tracked env/enc blobs and never prints values.

--consumer-bypass adds unguarded_mkdir and dockerignore columns. unguarded_mkdir
counts tracked Just/shell lines that mkdir/chmod env/dec (including Just-variable
forms "$path" / "$dec") before ores-sops can refuse a symlink. Matching lines are
never printed. dockerignore is ok, partial, missing, untracked, or invalid.

--strict exits non-zero unless every repository is adopted. Without --strict,
findings are reported but do not stop a fleet scan.
EOF
}

is_plaintext_env_path() {
  case "$1" in
    .env.example|*/.env.example) return 1 ;;
    .env|*.env|.env.*|*.env.*) return 0 ;;
    *) return 1 ;;
  esac
}

is_tracked() {
  git ls-files --error-unmatch -- "$1" >/dev/null 2>&1
}

tracked_mode() {
  git ls-files -s -- "$1" | awk 'NR == 1 { print $1 }'
}

sops_rule_state() {
  local file="$1"
  if [ ! -e "$file" ]; then
    printf 'missing
'
    return
  fi
  if ! is_tracked "$file"; then
    printf 'untracked
'
    return
  fi
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    printf 'invalid
'
    return
  fi

  awk '
    {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/^[[:space:]]*/, "", line)
    }
    line == "path_regex: ^env/enc/dev\.env\.enc$" { dev++; next }
    line == "path_regex: ^env/enc/stage\.env\.enc$" { stage++; next }
    line == "path_regex: ^env/enc/prod\.env\.enc$" { prod++; next }
    line ~ /^path_regex:/ && line ~ /env\/enc/ { broad = 1 }
    END {
      if (broad) print "broad"
      else if (dev != 1 || prod != 1 || stage > 1) print "missing"
      else if (stage == 1) print "exact-stage"
      else print "exact"
    }
  ' "$file"
}

ignore_contract_state() {
  local stage_enabled=0
  [ -e .gitignore ] || { printf 'missing
'; return; }
  is_tracked .gitignore || { printf 'untracked
'; return; }
  [ -f .gitignore ] || { printf 'invalid
'; return; }
  [ ! -L .gitignore ] || { printf 'invalid
'; return; }

  if [ -f .sops.yaml ] && grep -Fq 'path_regex: ^env/enc/stage\.env\.enc$' .sops.yaml; then
    stage_enabled=1
  fi
  is_tracked env/enc/stage.env.enc && stage_enabled=1

  git check-ignore --no-index -q .env || { printf 'missing
'; return; }
  git check-ignore --no-index -q sample.env || { printf 'missing
'; return; }
  git check-ignore --no-index -q sample.env.local || { printf 'missing
'; return; }
  git check-ignore --no-index -q env/dec/dev.env || { printf 'missing
'; return; }
  git check-ignore --no-index -q env/dec/stage.env || { printf 'missing
'; return; }
  git check-ignore --no-index -q env/dec/prod.env || { printf 'missing
'; return; }
  if git check-ignore --no-index -q env/enc/dev.env.enc; then printf 'missing
'; return; fi
  if git check-ignore --no-index -q env/enc/prod.env.enc; then printf 'missing
'; return; fi
  if [ "$stage_enabled" -eq 1 ] && git check-ignore --no-index -q env/enc/stage.env.enc; then
    printf 'missing
'
    return
  fi
  printf 'ok
'
}

attrs_state() {
  [ -e .gitattributes ] || { printf 'missing\n'; return; }
  is_tracked .gitattributes || { printf 'untracked\n'; return; }
  [ -f .gitattributes ] || { printf 'invalid\n'; return; }
  [ ! -L .gitattributes ] || { printf 'invalid\n'; return; }
  grep -Fqx '/env/enc/*.env.enc text eol=lf' .gitattributes && printf 'ok\n' || printf 'missing\n'
}

unguarded_mkdir_count() {
  local f n count=0
  while IFS= read -r -d '' f; do
    case "$f" in
      justfile|Justfile|*.just|.just/*)
        # Just recipes often mkdir via a Just variable ($path / $dec bound to env/dec)
        # after checking only that leaf. Count those as the same bypass class.
        # The regex must match a literal "$path" / "$dec" in the file, not expand them.
        # shellcheck disable=SC2016
        n="$(git show ":$f" 2>/dev/null | grep -cE 'mkdir[[:space:]]+-p[[:space:]]+.*env/dec|mkdir[[:space:]]+-p[[:space:]]+"\$path"|mkdir[[:space:]]+-p[[:space:]]+"\$dec"|install[[:space:]]+-d[[:space:]]+(-m[[:space:]]+7?00[[:space:]]+)?env/dec|chmod[[:space:]]+7?00[[:space:]]+(env/dec|"\$path"|"\$dec")' || true)"
        count=$((count + n))
        ;;
      scripts/*.sh)
        # Count shell commands only. Policy scripts that mention the forbidden
        # mkdir string in a Python check must not inflate the bypass tally.
        n="$(git show ":$f" 2>/dev/null | grep -cE '^[[:space:]]*mkdir[[:space:]]+-p[[:space:]].*env/dec|^[[:space:]]*chmod[[:space:]]+700[[:space:]]+env/dec' || true)"
        count=$((count + n))
        ;;
    esac
  done < <(git ls-files -z)
  printf '%d\n' "$count"
}

dockerignore_state() {
  local file=".dockerignore"
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
  if grep -Fq 'env/dec' "$file" && grep -Fq 'env/enc' "$file"; then
    printf 'ok\n'
  else
    printf 'partial\n'
  fi
}

provider_env_state() {
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

  [ -n "$joined" ] && printf '%s
' "$joined" || printf 'none
'
}

audit_one() {
  local requested="$1" root label
  local plaintext=0 unexpected=0 symlinks=0 env_enc_count=0 signals=0
  local tracked_env_dec=0 unguarded_mkdir=0 stage_allowed=0
  local f mode rules ignore attrs status sendgrid_envs twilio_envs dockerignore
  local extra=()

  root="$(git -C "$requested" rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'ores-sops-fleet-audit: not a git repository: %q\n' "$requested" >&2
    return 2
  }
  label="$(basename "$root")"

  (
    cd "$root"

    if [ -f .sops.yaml ] && grep -Fq 'path_regex: ^env/enc/stage\.env\.enc$' .sops.yaml; then
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
        env/enc/*)
          env_enc_count=$((env_enc_count + 1))
          unexpected=$((unexpected + 1))
          [ "$mode" != 120000 ] || symlinks=$((symlinks + 1))
          ;;
        env/dec/*)
          plaintext=$((plaintext + 1))
          tracked_env_dec=$((tracked_env_dec + 1))
          [ "$mode" != 120000 ] || symlinks=$((symlinks + 1))
          ;;
        .sops.yaml|.gitignore|.gitattributes|.env.example)
          [ "$mode" != 120000 ] || symlinks=$((symlinks + 1))
          ;;
        *)
          if is_plaintext_env_path "$f"; then
            plaintext=$((plaintext + 1))
          fi
          ;;
      esac
    done < <(git ls-files -z)

    rules="$(sops_rule_state .sops.yaml)"
    ignore="$(ignore_contract_state)"
    attrs="$(attrs_state)"

    [ -e .sops.yaml ] && signals=$((signals + 1))
    [ "$env_enc_count" -gt 0 ] && signals=$((signals + 1))
    [ -e .gitattributes ] && signals=$((signals + 1))
    if [ -f .gitignore ] && grep -Fq 'BEGIN ores-sops dotenv policy' .gitignore; then
      signals=$((signals + 1))
    fi

    if [ "$plaintext" -gt 0 ] || [ "$unexpected" -gt 0 ] || [ "$symlinks" -gt 0 ] || [ "$rules" = broad ] || [ "$rules" = invalid ] || [ "$ignore" = invalid ] || [ "$attrs" = invalid ]; then
      status=conflicting
    elif { [ "$rules" = exact ] || [ "$rules" = exact-stage ]; } && [ "$ignore" = ok ] && [ "$attrs" = ok ]; then
      status=adopted
    elif [ "$signals" -eq 0 ]; then
      status=not-adopted
    else
      status=partial
    fi

    extra=()
    if [ "$provider_inventory" -eq 1 ]; then
      sendgrid_envs="$(provider_env_state '(^|_)SENDGRID(_|$)')"
      twilio_envs="$(provider_env_state '(^|_)TWILIO(_|$)')"
      extra+=("$tracked_env_dec" "$sendgrid_envs" "$twilio_envs")
    fi
    if [ "$consumer_bypass" -eq 1 ]; then
      unguarded_mkdir="$(unguarded_mkdir_count)"
      dockerignore="$(dockerignore_state)"
      extra+=("$unguarded_mkdir" "$dockerignore")
    fi

    printf '%s\t%s\t%d\t%d\t%d\t%s\t%s\t%s' \
      "$label" "$status" "$plaintext" "$unexpected" "$symlinks" "$rules" "$ignore" "$attrs"
    if [ "${#extra[@]}" -gt 0 ]; then
      printf '\t%s' "${extra[@]}"
    fi
    printf '\n'

    case "$status" in
      adopted) exit 0 ;;
      conflicting) exit 2 ;;
      *) exit 1 ;;
    esac
  )
}

strict=0
provider_inventory=0
consumer_bypass=0
repos=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) strict=1 ;;
    --provider-inventory) provider_inventory=1 ;;
    --consumer-bypass) consumer_bypass=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; repos+=("$@"); break ;;
    -*) printf 'ores-sops-fleet-audit: unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
    *) repos+=("$1") ;;
  esac
  shift
done

[ "${#repos[@]}" -gt 0 ] || repos=(.)

header=$'repository\tstatus\ttracked_plaintext\tunexpected_env_enc\ttracked_symlinks\tsops_rules\tignore_contract\tciphertext_attributes'
if [ "$provider_inventory" -eq 1 ]; then
  header+=$'\ttracked_env_dec\tsendgrid_envs\ttwilio_envs'
fi
if [ "$consumer_bypass" -eq 1 ]; then
  header+=$'\tunguarded_mkdir\tdockerignore'
fi
printf '%s\n' "$header"

worst=0
for repo in "${repos[@]}"; do
  rc=0
  audit_one "$repo" || rc=$?
  if [ "$rc" -gt "$worst" ]; then worst="$rc"; fi
done

if [ "$strict" -eq 1 ]; then
  exit "$worst"
fi
exit 0
