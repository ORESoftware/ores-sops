#!/usr/bin/env bash
# Validate repository convenience/build artifacts from the exact candidate Git index.

set -euo pipefail

fail() {
  printf 'ores-sops repository boundary: %s\n' "$*" >&2
  exit 1
}

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$root" ] || fail "not inside a Git repository"
cd "$root"

candidate_tree="$(git write-tree 2>/dev/null)" || fail "candidate Git index cannot be serialized"
[ -n "$candidate_tree" ] || fail "candidate Git index did not produce a tree"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

just_entry="$(git ls-tree "$candidate_tree" -- justfile)"
[ -n "$just_entry" ] || fail "missing canonical justfile from candidate Git index"
read -r just_mode just_type just_object just_path <<<"$just_entry"
[ "$just_type" = "blob" ] || fail "justfile must be a blob"
[ "$just_path" = "justfile" ] || fail "candidate tree returned an unexpected justfile path"
case "$just_mode" in
  100644) ;;
  120000) fail "justfile must not be a symlink" ;;
  *) fail "justfile must be tracked as a non-executable regular file" ;;
esac
git cat-file blob "$just_object" >"$tmp/justfile"

ignore_entry="$(git ls-tree "$candidate_tree" -- .gitignore)"
[ -n "$ignore_entry" ] || fail "missing .gitignore from candidate Git index"
read -r ignore_mode ignore_type ignore_object ignore_path <<<"$ignore_entry"
[ "$ignore_type" = "blob" ] || fail ".gitignore must be a blob"
[ "$ignore_path" = ".gitignore" ] || fail "candidate tree returned an unexpected .gitignore path"
[ "$ignore_mode" = "100644" ] || fail ".gitignore must be a non-executable regular file"
git cat-file blob "$ignore_object" >"$tmp/gitignore"

grep -Fxq 'result' "$tmp/gitignore" || fail ".gitignore must ignore result"
grep -Fxq 'result-*' "$tmp/gitignore" || fail ".gitignore must ignore result-*"

tracked_build_output=0
while IFS= read -r -d '' path; do
  case "$path" in
    result|result-*|*/result|*/result-*) tracked_build_output=1 ;;
  esac
done < <(git ls-tree -r -z --name-only "$candidate_tree")
[ "$tracked_build_output" = 0 ] || fail "tracked Nix result/result-* build output found"

# Emit the most specific security diagnostics before the generic closed recipe
# namespace. This keeps failures attributable without weakening either check.
if grep -Eq '(^|[[:space:];|&])sops([[:space:]]|$)' "$tmp/justfile"; then
  fail "justfile must not invoke sops directly"
fi
if grep -Eq '(mkdir|install|chmod)[^#]*env/dec' "$tmp/justfile"; then
  fail "justfile must not create or chmod env/dec directly"
fi

required_recipes=(
  default audit test-contract ensure-dec list-encrypted check-ignore
  use-dev use-prod use-force-dev use-force-prod
  encrypt-dev encrypt-prod edit-dev edit-prod diff-dev diff-prod
  status refresh verify lock install-hooks check
)
approved_recipes=' default audit test-contract ensure-dec list-encrypted check-ignore use-dev use-prod use-force-dev use-force-prod encrypt-dev encrypt-prod edit-dev edit-prod diff-dev diff-prod status refresh verify lock install-hooks check '

sed -nE 's/^([A-Za-z0-9_-]+):$/\1/p' "$tmp/justfile" >"$tmp/recipes"
for recipe in "${required_recipes[@]}"; do
  grep -Fxq "$recipe" "$tmp/recipes" || fail "justfile is missing recipe: $recipe"
done

while IFS= read -r recipe; do
  case "$approved_recipes" in
    *" $recipe "*) ;;
    *) fail "justfile contains an unapproved recipe: $recipe" ;;
  esac
done <"$tmp/recipes"

duplicate_recipes="$(LC_ALL=C sort "$tmp/recipes" | uniq -d)"
[ -z "$duplicate_recipes" ] || fail "justfile contains duplicate recipe declarations"

# The repository Just boundary is declarative and closed: every secret-adjacent
# operation delegates to the tracked local helper, while the full gate delegates
# to the pinned Nix flake. Reject PATH shadowing, aliases, and newly introduced
# shell bodies until policy is updated.
while IFS= read -r raw; do
  line="$(printf '%s\n' "$raw" | sed 's/^[[:space:]]*//')"
  case "$line" in
    "@just --list" | \
    "python3 tools/audit_env_contract.py" | \
    "python3 -m unittest discover -s test -p 'test_audit_env_contract.py' -v" | \
    "@if [[ -d env/enc ]]; then find env/enc -type f -name '*.env.enc' -print | LC_ALL=C sort; fi" | \
    "git check-ignore --quiet .env" | \
    "git check-ignore --quiet env/dec/runtime.env" | \
    "./ores-sops ensure-dec" | \
    "./ores-sops use dev" | \
    "./ores-sops use prod" | \
    "./ores-sops use --force dev" | \
    "./ores-sops use --force prod" | \
    "./ores-sops encrypt dev" | \
    "./ores-sops encrypt prod" | \
    "./ores-sops edit dev" | \
    "./ores-sops edit prod" | \
    "./ores-sops diff dev" | \
    "./ores-sops diff prod" | \
    "./ores-sops status" | \
    "./ores-sops refresh" | \
    "./ores-sops verify" | \
    "./ores-sops lock" | \
    "./ores-sops install-hooks" | \
    "nix flake check -L") ;;
    *) fail "justfile contains an unapproved recipe command: $line" ;;
  esac
done < <(grep -E '^[[:space:]]+[^#[:space:]]' "$tmp/justfile" || true)

printf 'ores-sops repository boundary: PASS\n'
