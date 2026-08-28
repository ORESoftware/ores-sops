#!/usr/bin/env bats

repo_fixture() {
  local candidate
  for candidate in \
    "${BATS_TEST_DIRNAME}/.." \
    "${BATS_TEST_DIRNAME}/../.." \
    "$PWD" \
    "$PWD/.."
  do
    if [ -f "$candidate/templates/consumer.dockerignore" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

@test "consumer dockerignore excludes plaintext ciphertext and private-key artifacts" {
  root="$(repo_fixture)"
  [ -n "$root" ]
  file="$root/templates/consumer.dockerignore"

  grep -Fxq '.env' "$file"
  grep -Fxq '.env.*' "$file"
  grep -Fxq '**/*.env' "$file"
  grep -Fxq '**/*.env.*' "$file"
  grep -Fxq 'env/dec' "$file"
  grep -Fxq 'env/dec/**' "$file"
  grep -Fxq 'env/enc' "$file"
  grep -Fxq 'env/enc/**' "$file"
  grep -Fxq '**/*.pem' "$file"
  grep -Fxq '**/*.key' "$file"
  grep -Fxq '**/*.p8' "$file"
  grep -Fxq '**/*service-account*.json' "$file"

  ! grep -E 'AGE-SE''CRET-KEY-1|-----BEGIN ''PRIVATE KEY-----' "$file"
}

@test "example container entrypoint never evals decrypted values" {
  root="$(repo_fixture)"
  [ -n "$root" ]
  file="$root/examples/docker/entrypoint.sh"

  grep -Fq 'exec "$@"' "$file"
  grep -Fq 'export "$key=$value"' "$file"
  ! grep -Eq '(^|[[:space:]])eval[[:space:]]' "$file"
  # Comments may mention sops exec-env as the anti-pattern; the script must not invoke it.
  ! grep -Eq '^[^#]*sops[[:space:]]+exec-env' "$file"
}
