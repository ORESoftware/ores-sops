#!/usr/bin/env bash
set +x
set -euo pipefail
source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
umask 077
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
trap 'exit 130' HUP INT TERM
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
mkdir -p "$tmp/repo/scripts"
cd "$tmp/repo"
git init -q --template=
cp "$source_root/scripts/check-env-index.sh" scripts/
git add scripts/check-env-index.sh
bash scripts/check-env-index.sh >/dev/null

# Private key headers are denied without reflecting the matched material.
for kind in '' 'RSA ' 'OPENSSH '; do
  printf -- '-----BE%s%sPRIVATE KEY-----\n' 'GIN ' "$kind" > candidate.txt
  git add candidate.txt
  if bash scripts/check-env-index.sh > "$tmp/output" 2>&1; then
    echo 'expected synthetic private-key header rejection' >&2; exit 1
  fi
  ! grep -q 'PRIVATE KEY' "$tmp/output"
done
git reset -q -- candidate.txt
rm -f candidate.txt

# The documented example suffixes are safe to track, but policy/example files
# themselves must not become executable or symlinks.
printf 'EXAMPLE_ONLY=replace-me\n' > .env.example
printf 'SAMPLE_ONLY=replace-me\n' > .env.sample
printf 'TEMPLATE_ONLY=replace-me\n' > .env.template
git add .env.example .env.sample .env.template
bash scripts/check-env-index.sh >/dev/null
chmod 755 .env.sample
git add .env.sample
if bash scripts/check-env-index.sh > "$tmp/output" 2>&1; then
  echo 'expected executable example rejection' >&2; exit 1
fi
chmod 644 .env.sample
git add .env.sample
bash scripts/check-env-index.sh >/dev/null

write_stage_policy() {
  cat > .sops.yaml <<'EOF_POLICY'
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
  - path_regex: ^env/enc/stage\.env\.enc$
  - path_regex: ^env/enc/prod\.env\.enc$
EOF_POLICY
}

# Stage is optional, but when present it is admitted only from the exact staged
# .sops.yaml rule. The working tree is not consulted for this decision.
mkdir -p env/enc
write_stage_policy
cat > env/enc/stage.env.enc <<'EOF_CIPHERTEXT'
EXAMPLE=ENC[AES256_GCM,data:AA==,iv:AA==,tag:AA==,type:str]
sops_mac=ENC[AES256_GCM,data:AA==,iv:AA==,tag:AA==,type:str]
EOF_CIPHERTEXT
git add .sops.yaml env/enc/stage.env.enc
bash scripts/check-env-index.sh >/dev/null

# An unstaged policy replacement must not change the candidate-index decision.
grep -v 'stage' .sops.yaml > .sops.yaml.worktree
mv .sops.yaml.worktree .sops.yaml
bash scripts/check-env-index.sh >/dev/null

# Once the policy replacement is staged, stage ciphertext is rejected.
git add .sops.yaml
if bash scripts/check-env-index.sh > "$tmp/output" 2>&1; then
  echo 'expected stage ciphertext without staged stage rule rejection' >&2; exit 1
fi

# Restore a valid staged stage policy for the remaining independent regressions.
write_stage_policy
git add .sops.yaml
bash scripts/check-env-index.sh >/dev/null

# Plaintext dotenv variants remain forbidden.
printf 'SECRET=plaintext\n' > .env.local
git add -f .env.local
if bash scripts/check-env-index.sh > "$tmp/output" 2>&1; then
  echo 'expected tracked plaintext dotenv rejection' >&2; exit 1
fi
git reset -q -- .env.local
rm -f .env.local

# The staged policy file itself is data, not an executable surface.
chmod 755 .sops.yaml
git add .sops.yaml
if bash scripts/check-env-index.sh > "$tmp/output" 2>&1; then
  echo 'expected executable .sops.yaml rejection' >&2; exit 1
fi

printf 'PASS: index scanner self-test, stage admission, examples, modes, plaintext and private-key regressions\n'
