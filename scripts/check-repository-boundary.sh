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
    result|result-*) tracked_build_output=1 ;;
  esac
done < <(git ls-tree -r -z --name-only "$candidate_tree")
[ "$tracked_build_output" = 0 ] || fail "tracked Nix result/result-* build output found"

required_recipes=(
  default ensure-dec use-dev use-prod use-force-dev use-force-prod
  encrypt-dev encrypt-prod edit-dev edit-prod diff-dev diff-prod
  status refresh verify lock install-hooks check
)
for recipe in "${required_recipes[@]}"; do
  grep -Eq "^${recipe}:$" "$tmp/justfile" || fail "justfile is missing recipe: $recipe"
done

# The repository Just boundary is intentionally declarative and closed: every
# secret-adjacent operation delegates to ores-sops, while the full gate delegates
# to the pinned Nix flake. Reject direct SOPS, ad-hoc env/dec creation, and any
# newly introduced shell body until it receives an explicit policy update.
if grep -Eq '(^|[[:space:];|&])sops([[:space:]]|$)' "$tmp/justfile"; then
  fail "justfile must not invoke sops directly"
fi
if grep -Eq '(mkdir|install|chmod)[^#]*env/dec' "$tmp/justfile"; then
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
' "$tmp/justfile"; then
  fail "justfile contains an unapproved recipe command"
fi

printf 'ores-sops repository boundary: PASS\n'
