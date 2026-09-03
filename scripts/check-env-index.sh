#!/usr/bin/env bash
# Keyless check of the exact Git index, not unstaged replacement files.
# This checks structure, not cryptographic integrity or recipient custody.
set +x
set -euo pipefail

fail() { printf 'encrypted-env index: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 0 ] || fail 'no arguments are accepted'
root=$(git rev-parse --show-toplevel 2>/dev/null) || fail 'not inside a Git repository'
cd "$root"

# write-tree freezes the candidate snapshot and rejects unresolved conflicts.
# It creates only Git metadata; no plaintext is materialized in the worktree.
tree=$(git write-tree 2>/dev/null) || fail 'cannot snapshot the index (resolve conflicts first)'
umask 077
listing=$(mktemp) || fail 'cannot allocate index listing'
trap 'rm -f -- "$listing"' EXIT
trap 'exit 130' HUP INT TERM
git ls-tree -r -z --full-tree "$tree" > "$listing" || fail 'cannot enumerate index snapshot'

ciphertext_shape() {
  LC_ALL=C awk '
    function encrypted(v) {
      return v ~ /^ENC\[AES256_GCM,data:[A-Za-z0-9+\/=]*,iv:[A-Za-z0-9+\/=]+,tag:[A-Za-z0-9+\/=]+,type:str\]$/
    }
    /^[[:space:]]*$/ || /^#/ { next }
    !/^[A-Za-z_][A-Za-z0-9_]*=/ { bad=1; next }
    {
      key=$0; sub(/=.*/, "", key)
      value=substr($0, length(key)+2)
      if (seen[key]++) bad=1
      if (key == "sops_mac") { mac++; if (!encrypted(value)) bad=1; next }
      if (key ~ /^sops_(lastmodified|version|shamir_threshold|mac_only_encrypted|unencrypted_suffix|encrypted_suffix|unencrypted_regex|encrypted_regex|unencrypted_comment_regex|encrypted_comment_regex)$/) next
      if (key ~ /^sops_(age|kms|pgp|gcp_kms|azure_kv|hc_vault|hckms|key_groups)__list_[0-9]+__map_[A-Za-z0-9_]+$/) next
      if (key ~ /^sops_/ || !encrypted(value)) bad=1
    }
    END { exit (bad || mac != 1) ? 1 : 0 }
  '
}

while IFS= read -r -d '' entry; do
  metadata=${entry%%$'\t'*}
  path=${entry#*$'\t'}
  read -r mode kind oid <<< "$metadata"
  printf -v shown '%q' "$path"
  case "$path" in
    env|env/dec|env/dec/*|*/env/dec|*/env/dec/*)
      fail "tracked decrypted path (no placeholder exceptions): $shown" ;;
    env/enc/dev.env.enc|env/enc/prod.env.enc)
      [ "$kind:$mode" = blob:100644 ] || fail "ciphertext must be a non-executable regular blob: $shown"
      git cat-file blob "$oid" | ciphertext_shape || fail "invalid SOPS dotenv structure in staged blob: $shown"
      ;;
    env/enc|env/enc/*)
      fail "unexpected tracked ciphertext path: $shown" ;;
    .dockerignore|.gitignore|.gitattributes|.sops.yaml|justfile|.env.example|*/.env.example)
      case "$kind:$mode" in blob:100644|blob:100755) ;; *) fail "policy/example must be a regular blob: $shown" ;; esac
      ;;
    .env|*/.env|*.env|.env.*|*/.env.*|*.env.*)
      fail "tracked plaintext dotenv path: $shown" ;;
  esac
done < "$listing"

# Snapshot-based and binary-aware; never print matched material. Split markers
# keep this scanner and its synthetic test source from matching themselves.
age_marker='AGE-SE''CRET-KEY-1'
pem_marker='-----BE''GIN [A-Z ]*PRIVATE KEY-----'
rc=0
git grep -a -q -E -e "$age_marker" -e "$pem_marker" "$tree" -- . || rc=$?
case "$rc" in
  0) fail 'private-key material exists in the index snapshot' ;;
  1) ;;
  *) fail 'private-key scan failed; no success claim is made' ;;
esac
printf 'encrypted-env index: candidate snapshot passed (keyless, no decrypt)\n'
