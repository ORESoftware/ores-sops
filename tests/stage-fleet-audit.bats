#!/usr/bin/env bats

setup_repo() {
  local dir="$1" with_stage_rule="$2"
  mkdir -p "$dir"
  cd "$dir"
  git init -q .
  git config user.email stage-fleet@example.invalid
  git config user.name stage-fleet-test
  git config commit.gpgsign false

  cat > .sops.yaml <<'EOF_SOPS'
creation_rules:
  - path_regex: ^env/enc/dev\.env\.enc$
    age:
      - age1dddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
EOF_SOPS
  if [ "$with_stage_rule" = yes ]; then
    cat >> .sops.yaml <<'EOF_STAGE'
  - path_regex: ^env/enc/stage\.env\.enc$
    age:
      - age1ssssssssssssssssssssssssssssssssssssssssssssssssssssssssss
EOF_STAGE
  fi
  cat >> .sops.yaml <<'EOF_PROD'
  - path_regex: ^env/enc/prod\.env\.enc$
    age:
      - age1pppppppppppppppppppppppppppppppppppppppppppppppppppppp
EOF_PROD

  cat > .gitignore <<'EOF_IGNORE'
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
EOF_IGNORE
  if [ "$with_stage_rule" = yes ]; then
    printf '!/env/enc/stage.env.enc\n' >> .gitignore
  fi
  printf '/env/enc/*.env.enc text eol=lf\n' > .gitattributes
  git add .sops.yaml .gitignore .gitattributes
  git commit -qm policy
}

@test "fleet audit adopts optional exact stage policy" {
  repo="$BATS_TEST_TMPDIR/stage-adopted"
  setup_repo "$repo" yes

  run ores-sops-fleet-audit --strict "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\tadopted\t'* ]]
  [[ "$output" == *$'\texact-stage\tok\tok'* ]]
}

@test "tracked stage ciphertext without exact stage rule is conflicting" {
  repo="$BATS_TEST_TMPDIR/stage-conflict"
  setup_repo "$repo" no
  mkdir -p env/enc
  printf 'DUMMY=ENC[fake]\nsops_mac=ENC[fake]\n' > env/enc/stage.env.enc
  git add -f env/enc/stage.env.enc
  git commit -qm stage-without-rule

  run ores-sops-fleet-audit "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\tconflicting\t'* ]]
  [[ "$output" == *$'\t1\t0\texact\t'* ]]
}
