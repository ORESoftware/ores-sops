#!/usr/bin/env bash
# Validate repository-local convenience/build artifacts without reading secrets.

set -euo pipefail

fail() {
  printf 'ores-sops repository boundary: %s\n' "$*" >&2
  exit 1
}

root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$root" ] || fail "not inside a Git repository"
cd "$root"

if [ ! -e justfile ] && [ ! -L justfile ]; then
  fail "missing canonical justfile"
fi
[ ! -L justfile ] || fail "justfile must not be a symlink"
[ -f justfile ] || fail "justfile must be a regular file"
mode="$(git ls-files -s -- justfile | awk 'NR == 1 { print $1 }')"
[ "$mode" = "100644" ] || fail "justfile must be tracked as a non-executable regular file"

grep -Fxq 'result' .gitignore || fail ".gitignore must ignore result"
grep -Fxq 'result-*' .gitignore || fail ".gitignore must ignore result-*"

tracked_build_output=0
while IFS= read -r -d '' path; do
  case "$path" in
    result|result-*) tracked_build_output=1 ;;
  esac
done < <(git ls-files -z -- 'result' 'result-*')
[ "$tracked_build_output" = 0 ] || fail "tracked Nix result/result-* build output found"

required_recipes=(
  default ensure-dec use-dev use-prod use-force-dev use-force-prod
  encrypt-dev encrypt-prod edit-dev edit-prod diff-dev diff-prod
  status refresh verify lock install-hooks check
)
for recipe in "${required_recipes[@]}"; do
  grep -Eq "^${recipe}:$" justfile || fail "justfile is missing recipe: $recipe"
done

# The repository Just boundary is intentionally declarative and closed: every
# secret-adjacent operation delegates to ores-sops, while the full gate delegates
# to the pinned Nix flake. Reject direct SOPS, ad-hoc env/dec creation, and any
# newly introduced shell body until it receives an explicit policy update.
if grep -Eq '(^|[[:space:];|&])sops([[:space:]]|$)' justfile; then
  fail "justfile must not invoke sops directly"
fi
if grep -Eq '(mkdir|install|chmod)[^#]*env/dec' justfile; then
  fail "justfile must not create or chmod env/dec directly"
fi

if ! awk '
  /^[[:space:]]+[^#[:space:]]/ {
    line=$0
    sub(/^[[:space:]]+/, "", line)
    if (line == "@just --list") next
    if (line == "nix flake check -L") next
    if (line ~ /^ores-sops (ensure-dec|status|refresh|verify|lock|install-hooks)$/) next
    if (line ~ /^ores-sops (use|encrypt|edit|diff) (dev|prod)$/) next
    if (line ~ /^ores-sops use --force (dev|prod)$/) next
    exit 1
  }
' justfile; then
  fail "justfile contains an unapproved recipe command"
fi

printf 'ores-sops repository boundary: PASS\n'
