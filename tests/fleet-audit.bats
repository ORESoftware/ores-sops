#!/usr/bin/env bats

init_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q .
  git -C "$path" config user.email fleet@example.invalid
  git -C "$path" config user.name fleet-test
  git -C "$path" config commit.gpgsign false
}

write_policy_files() {
  local path="$1"
  cat >"$path/.gitignore" <<'EOF_IGNORE'
# BEGIN ores-sops dotenv policy
*.env
*/*.env
*/**/*.env
.env.*
*.env.*
!.env.example
/env/dec/
/env/enc/*
!/env/enc/dev.env.enc
!/env/enc/prod.env.enc
# END ores-sops dotenv policy
EOF_IGNORE
  printf '/env/enc/*.env.enc text eol=lf\n' >"$path/.gitattributes"
  cat >"$path/.sops.yaml" <<'EOF_SOPS'
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
  - path_regex: ^env/enc/prod\.env\.enc$
    age:
      - age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
EOF_SOPS
}

write_adopted_policy() {
  local path="$1"
  write_policy_files "$path"
  git -C "$path" add .gitignore .gitattributes .sops.yaml
  git -C "$path" commit -qm policy
}

setup() {
  export ROOT="$BATS_TEST_TMPDIR/fleet"
  mkdir -p "$ROOT"
}

@test "reports a canonical repository as adopted without decrypting" {
  repo="$ROOT/adopted"
  init_repo "$repo"
  write_adopted_policy "$repo"

  run ores-sops-fleet-audit "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'adopted\tadopted\t0\t0\t0\texact\tok\tok'* ]]
}

@test "reports a repository with no adoption signal as not-adopted" {
  repo="$ROOT/plain"
  init_repo "$repo"
  printf '# ordinary repository\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm baseline

  run ores-sops-fleet-audit "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'plain\tnot-adopted\t0\t0\t0\tmissing\tmissing\tmissing'* ]]

  run ores-sops-fleet-audit --strict "$repo"
  [ "$status" -eq 1 ]
}

@test "reports tracked plaintext and broad env rules as conflicting without printing values" {
  repo="$ROOT/conflict"
  init_repo "$repo"
  write_adopted_policy "$repo"
  cat >>"$repo/.sops.yaml" <<'EOF_BROAD'
  - path_regex: ^env/enc/.*\.env\.enc$
    age:
      - age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq
EOF_BROAD
  printf 'TOP_SECRET_SHOULD_NOT_APPEAR=dummy-sensitive-marker\n' >"$repo/leak.env"
  mkdir -p "$repo/env/enc"
  printf 'not-read-by-audit\n' >"$repo/env/enc/staging.env.enc"
  git -C "$repo" add .sops.yaml
  git -C "$repo" add -f leak.env env/enc/staging.env.enc
  git -C "$repo" commit -qm conflict
  chmod 000 "$repo/leak.env" "$repo/env/enc/staging.env.enc"

  run ores-sops-fleet-audit "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'conflict\tconflicting\t1\t1\t0\tbroad\tok\tok'* ]]
  [[ "$output" != *"TOP_SECRET_SHOULD_NOT_APPEAR"* ]]
  [[ "$output" != *"dummy-sensitive-marker"* ]]
  [[ "$output" != *"not-read-by-audit"* ]]

  run ores-sops-fleet-audit --strict "$repo"
  [ "$status" -eq 2 ]
}

@test "reports a partially scaffolded repository as partial" {
  repo="$ROOT/partial"
  init_repo "$repo"
  printf '# BEGIN ores-sops dotenv policy\n*.env\n' >"$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -qm partial

  run ores-sops-fleet-audit "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'partial\tpartial\t0\t0\t0\tmissing\tmissing\tmissing'* ]]
}

@test "does not classify untracked local policy files as adopted" {
  repo="$ROOT/untracked"
  init_repo "$repo"
  printf '# baseline\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -qm baseline
  write_policy_files "$repo"

  run ores-sops-fleet-audit "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'untracked\tpartial\t0\t0\t0\tuntracked\tuntracked\tuntracked'* ]]

  run ores-sops-fleet-audit --strict "$repo"
  [ "$status" -eq 1 ]
}

@test "provider inventory reports environments without exposing ciphertext values" {
  repo="$ROOT/providers"
  init_repo "$repo"
  write_adopted_policy "$repo"
  mkdir -p "$repo/env/enc"
  cat >"$repo/env/enc/dev.env.enc" <<'EOF_DEV'
AUTH_SENDGRID_API_KEY=ENC[AES256_GCM,data:sendgrid-secret-marker,iv:a,tag:b,type:str]
AUTH_TWILIO_ACCOUNT_SID=ENC[AES256_GCM,data:twilio-secret-marker,iv:c,tag:d,type:str]
sops_version=3.13.3
EOF_DEV
  cat >"$repo/env/enc/prod.env.enc" <<'EOF_PROD'
SENDGRID_API_KEY=ENC[AES256_GCM,data:prod-secret-marker,iv:e,tag:f,type:str]
sops_version=3.13.3
EOF_PROD
  git -C "$repo" add env/enc/dev.env.enc env/enc/prod.env.enc
  git -C "$repo" commit -qm providers
  chmod 000 "$repo/env/enc/dev.env.enc" "$repo/env/enc/prod.env.enc"

  run ores-sops-fleet-audit --provider-inventory "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'providers\tadopted\t0\t0\t0\texact\tok\tok\t0\tdev+prod\tdev'* ]]
  [[ "$output" != *"sendgrid-secret-marker"* ]]
  [[ "$output" != *"twilio-secret-marker"* ]]
  [[ "$output" != *"prod-secret-marker"* ]]
}

@test "default scan keeps the original header even when provider names exist" {
  repo="$ROOT/default-scan"
  init_repo "$repo"
  write_adopted_policy "$repo"
  mkdir -p "$repo/env/enc"
  cat >"$repo/env/enc/dev.env.enc" <<'EOF_DEV'
SENDGRID_API_KEY=ENC[AES256_GCM,data:must-not-print,iv:a,tag:b,type:str]
sops_version=3.13.3
EOF_DEV
  git -C "$repo" add env/enc/dev.env.enc
  git -C "$repo" commit -qm default-scan
  chmod 000 "$repo/env/enc/dev.env.enc"

  run ores-sops-fleet-audit "$repo"
  [ "$status" -eq 0 ]
  header="$(printf '%s\n' "$output" | head -n1)"
  [ "$header" = $'repository\tstatus\ttracked_plaintext\tunexpected_env_enc\ttracked_symlinks\tsops_rules\tignore_contract\tciphertext_attributes' ]
  [[ "$output" != *"sendgrid_envs"* ]]
  [[ "$output" != *"twilio_envs"* ]]
  [[ "$output" != *"must-not-print"* ]]
  [[ "$output" != *"SENDGRID_API_KEY"* ]]
}

@test "provider inventory reports none when only ciphertext values mention the provider" {
  repo="$ROOT/value-only"
  init_repo "$repo"
  write_adopted_policy "$repo"
  mkdir -p "$repo/env/enc"
  cat >"$repo/env/enc/dev.env.enc" <<'EOF_DEV'
UNRELATED_TOKEN=ENC[AES256_GCM,data:SENDGRID_API_KEY,iv:a,tag:b,type:str]
sops_version=3.13.3
EOF_DEV
  git -C "$repo" add env/enc/dev.env.enc
  git -C "$repo" commit -qm value-only
  chmod 000 "$repo/env/enc/dev.env.enc"

  run ores-sops-fleet-audit --provider-inventory "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'value-only\tadopted\t0\t0\t0\texact\tok\tok\t0\tnone\tnone'* ]]
  [[ "$output" != *"SENDGRID_API_KEY"* ]]
}

@test "provider inventory ignores untracked env/enc blobs" {
  repo="$ROOT/untracked-enc"
  init_repo "$repo"
  write_adopted_policy "$repo"
  mkdir -p "$repo/env/enc"
  cat >"$repo/env/enc/dev.env.enc" <<'EOF_DEV'
SENDGRID_API_KEY=ENC[AES256_GCM,data:untracked-marker,iv:a,tag:b,type:str]
sops_version=3.13.3
EOF_DEV

  run ores-sops-fleet-audit --provider-inventory "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'untracked-enc\tadopted\t0\t0\t0\texact\tok\tok\t0\tnone\tnone'* ]]
  [[ "$output" != *"untracked-marker"* ]]
}

@test "provider inventory reports none none for adopted repos without provider keys" {
  repo="$ROOT/no-providers"
  init_repo "$repo"
  write_adopted_policy "$repo"

  run ores-sops-fleet-audit --provider-inventory "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'no-providers\tadopted\t0\t0\t0\texact\tok\tok\t0\tnone\tnone'* ]]
}

@test "unknown fleet-audit option fails closed without scanning" {
  run ores-sops-fleet-audit --decrypt-please "$ROOT"
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "consumer bypass counts unguarded mkdir without printing recipe bodies" {
  repo="$ROOT/bypass"
  init_repo "$repo"
  write_adopted_policy "$repo"
  cat >"$repo/justfile" <<'EOF_JUST'
use name:
    mkdir -p env/dec
    chmod 700 env/dec
    ores-sops use {{ name }}
EOF_JUST
  git -C "$repo" add justfile
  git -C "$repo" commit -qm bypass

  run ores-sops-fleet-audit --consumer-bypass "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'bypass\tadopted\t0\t0\t0\texact\tok\tok\t2\tmissing'* ]]
  [[ "$output" != *"ores-sops use"* ]]
}

@test "consumer bypass counts env.just variable mkdir without printing the recipe" {
  repo="$ROOT/just-var"
  init_repo "$repo"
  write_adopted_policy "$repo"
  mkdir -p "$repo/.just"
  cat >"$repo/.just/env.just" <<'EOF_JUST'
_env-dec:
    #!/usr/bin/env bash
    set -euo pipefail
    path="{{ _dec }}"
    mkdir -p "$path"
    chmod 700 "$path"
EOF_JUST
  git -C "$repo" add .just/env.just
  git -C "$repo" commit -qm just-var

  run ores-sops-fleet-audit --consumer-bypass "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'just-var\tadopted\t0\t0\t0\texact\tok\tok\t2\tmissing'* ]]
  [[ "$output" != *'_env-dec'* ]]
  [[ "$output" != *'mkdir -p "$path"'* ]]
}

@test "consumer bypass counts install -d env/dec without printing the recipe" {
  repo="$ROOT/install-d"
  init_repo "$repo"
  write_adopted_policy "$repo"
  cat >"$repo/justfile" <<'EOF_JUST'
decrypt:
    install -d -m 700 env/dec
    sops --decrypt env/enc/dev.env.enc
EOF_JUST
  git -C "$repo" add justfile
  git -C "$repo" commit -qm install-d

  run ores-sops-fleet-audit --consumer-bypass "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'install-d\tadopted\t0\t0\t0\texact\tok\tok\t1\tmissing'* ]]
  [[ "$output" != *"sops --decrypt"* ]]
}

@test "consumer bypass ignores policy scripts that mention mkdir as a forbidden string" {
  repo="$ROOT/policy-mention"
  init_repo "$repo"
  write_adopted_policy "$repo"
  mkdir -p "$repo/scripts"
  cat >"$repo/scripts/check-env-policy.sh" <<'EOF_SH'
#!/usr/bin/env bash
python3 - <<'PY'
text = open("justfile").read()
if "mkdir -p env/dec" in text:
    raise SystemExit("forbidden")
PY
EOF_SH
  git -C "$repo" add scripts/check-env-policy.sh
  git -C "$repo" commit -qm policy-mention

  run ores-sops-fleet-audit --consumer-bypass "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'policy-mention\tadopted\t0\t0\t0\texact\tok\tok\t0\tmissing'* ]]
}

@test "consumer bypass reports ok dockerignore without unguarded mkdir" {
  repo="$ROOT/guarded"
  init_repo "$repo"
  write_adopted_policy "$repo"
  cat >"$repo/justfile" <<'EOF_JUST'
use name:
    ores-sops ensure-dec
    ores-sops use {{ name }}
EOF_JUST
  cat >"$repo/.dockerignore" <<'EOF_DOCKER'
.env
env/dec
env/enc
EOF_DOCKER
  git -C "$repo" add justfile .dockerignore
  git -C "$repo" commit -qm guarded

  run ores-sops-fleet-audit --consumer-bypass "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'guarded\tadopted\t0\t0\t0\texact\tok\tok\t0\tok'* ]]
}

@test "provider inventory calls out tracked env dec files" {
  repo="$ROOT/tracked-dec"
  init_repo "$repo"
  write_adopted_policy "$repo"
  mkdir -p "$repo/env/dec"
  printf 'SECRET_VALUE=must-not-print\n' >"$repo/env/dec/dev.env"
  git -C "$repo" add -f env/dec/dev.env
  git -C "$repo" commit -qm tracked-dec
  chmod 000 "$repo/env/dec/dev.env"

  run ores-sops-fleet-audit --provider-inventory "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'tracked-dec\tconflicting\t1\t0\t0\texact\tok\tok\t1\tnone\tnone'* ]]
  [[ "$output" != *"SECRET_VALUE"* ]]
  [[ "$output" != *"must-not-print"* ]]

  run ores-sops-fleet-audit --strict --provider-inventory "$repo"
  [ "$status" -eq 2 ]
}
