#!/usr/bin/env bats

write_base_repo() {
  local root="$1"
  mkdir -p "$root/env/enc"
  git -C "$root" init -q
  git -C "$root" config user.email fleet-stage@example.invalid
  git -C "$root" config user.name fleet-stage
  git -C "$root" config commit.gpgsign false
  cat >"$root/.gitignore" <<'EOF_IGNORE'
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
  printf '/env/enc/*.env.enc text eol=lf\n' >"$root/.gitattributes"
}

write_ciphertext() {
  local path="$1"
  shift
  {
    for key in "$@"; do
      printf '%s=ENC[fake]\n' "$key"
    done
    printf 'sops_mac=ENC[fake]\n'
  } >"$path"
}

commit_repo() {
  local root="$1"
  git -C "$root" add .
  git -C "$root" commit -qm fixture
}

setup() {
  export ROOT="$BATS_TEST_TMPDIR/stage-fleet"
  mkdir -p "$ROOT"
}

@test "legacy dev prod repositories remain adopted" {
  repo="$ROOT/legacy"
  write_base_repo "$repo"
  cat >"$repo/.sops.yaml" <<'EOF_SOPS'
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1dddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  - path_regex: ^env/enc/prod\.env\.enc$
    age:
      - age1pppppppppppppppppppppppppppppppppppppppppppppppppppppppppp
EOF_SOPS
  write_ciphertext "$repo/env/enc/dev.env.enc" DEV_VALUE
  write_ciphertext "$repo/env/enc/prod.env.enc" PROD_VALUE
  commit_repo "$repo"

  run ores-sops-fleet-audit --strict "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'legacy\tadopted\t0\t0\t0\texact\tok\tok'* ]]
}

@test "exact optional stage repositories are adopted" {
  repo="$ROOT/with-stage"
  write_base_repo "$repo"
  printf '!/env/enc/stage.env.enc\n' >>"$repo/.gitignore"
  cat >"$repo/.sops.yaml" <<'EOF_SOPS'
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1dddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  - path_regex: ^env/enc/stage\.env\.enc$
    age:
      - age1ssssssssssssssssssssssssssssssssssssssssssssssssssssssssss
  - path_regex: ^env/enc/prod\.env\.enc$
    age:
      - age1pppppppppppppppppppppppppppppppppppppppppppppppppppppppppp
EOF_SOPS
  write_ciphertext "$repo/env/enc/dev.env.enc" DEV_VALUE SENDGRID_API_KEY
  write_ciphertext "$repo/env/enc/stage.env.enc" STAGE_VALUE SENDGRID_API_KEY TWILIO_AUTH_TOKEN
  write_ciphertext "$repo/env/enc/prod.env.enc" PROD_VALUE TWILIO_AUTH_TOKEN
  commit_repo "$repo"

  run ores-sops-fleet-audit --strict --provider-inventory "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'with-stage\tadopted\t0\t0\t0\texact\tok\tok\t0\tdev+stage\tstage+prod'* ]]
}

@test "tracked stage ciphertext without the exact stage rule is conflicting" {
  repo="$ROOT/stage-without-rule"
  write_base_repo "$repo"
  cat >"$repo/.sops.yaml" <<'EOF_SOPS'
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1dddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  - path_regex: ^env/enc/prod\.env\.enc$
    age:
      - age1pppppppppppppppppppppppppppppppppppppppppppppppppppppppppp
EOF_SOPS
  write_ciphertext "$repo/env/enc/dev.env.enc" DEV_VALUE
  write_ciphertext "$repo/env/enc/prod.env.enc" PROD_VALUE
  write_ciphertext "$repo/env/enc/stage.env.enc" STAGE_VALUE
  git -C "$repo" add .
  git -C "$repo" add -f env/enc/stage.env.enc
  git -C "$repo" commit -qm fixture

  run ores-sops-fleet-audit --strict "$repo"
  [ "$status" -eq 2 ]
  [[ "$output" == *$'stage-without-rule\tconflicting\t0\t1\t0\texact\tok\tok'* ]]
}

@test "a stage rule without the stage Git allowlist is partial, not falsely adopted" {
  repo="$ROOT/stage-ignore-missing"
  write_base_repo "$repo"
  cat >"$repo/.sops.yaml" <<'EOF_SOPS'
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1dddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  - path_regex: ^env/enc/stage\.env\.enc$
    age:
      - age1ssssssssssssssssssssssssssssssssssssssssssssssssssssssssss
  - path_regex: ^env/enc/prod\.env\.enc$
    age:
      - age1pppppppppppppppppppppppppppppppppppppppppppppppppppppppppp
EOF_SOPS
  write_ciphertext "$repo/env/enc/dev.env.enc" DEV_VALUE
  write_ciphertext "$repo/env/enc/prod.env.enc" PROD_VALUE
  commit_repo "$repo"

  run ores-sops-fleet-audit --strict "$repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *$'stage-ignore-missing\tpartial\t0\t0\t0\texact\tmissing\tok'* ]]
}
