import assert from 'node:assert/strict';
import test from 'node:test';
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

function makeFakeGh(dir, body) {
  const bin = join(dir, 'bin');
  mkdirSync(bin);
  const fakeGh = join(bin, 'gh');
  writeFileSync(fakeGh, `#!/usr/bin/env bash\nset -euo pipefail\n${body}\n`);
  chmodSync(fakeGh, 0o755);
  return bin;
}

const requirePinnedApiVersion = String.raw`
[[ "$*" == *"X-GitHub-Api-Version: 2026-03-10"* ]] || {
  printf 'missing pinned GitHub API version\n' >&2
  exit 92
}`;

test('GitHub API inventory keeps names/source classes and discards variable values', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ores-sops-gh-inventory-'));
  const output = join(dir, 'inventory.json');
  const bin = makeFakeGh(dir, String.raw`
${requirePinnedApiVersion}
case "$*" in
  *"repos/ORESoftware/example/environments/prod/secrets")
    printf '%s\n' '[{"secrets":[{"name":"ENV_SECRET","updated_at":"ignored"}]}]'
    ;;
  *"repos/ORESoftware/example/environments/prod/variables")
    printf '%s\n' '[{"variables":[{"name":"ENV_VAR","value":"env-variable-must-not-leak"}]}]'
    ;;
  *"repos/ORESoftware/example/actions/secrets")
    printf '%s\n' '[{"secrets":[{"name":"REPO_SECRET","created_at":"ignored"}]}]'
    ;;
  *"repos/ORESoftware/example/actions/variables")
    printf '%s\n' '[{"variables":[{"name":"REPO_VAR","value":"repo-variable-must-not-leak"}]}]'
    ;;
  *)
    printf 'unexpected endpoint\n' >&2
    exit 91
    ;;
esac`);

  const result = spawnSync(process.execPath, ['scripts/inventory-github-actions-config.mjs'], {
    cwd: new URL('..', import.meta.url),
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      ORES_SOPS_GHA_REPOSITORY: 'ORESoftware/example',
      ORES_SOPS_GHA_ENVIRONMENT: 'prod',
      ORES_SOPS_GHA_INVENTORY_FILE: output,
    },
    encoding: 'utf8',
  });

  assert.equal(result.status, 0, result.stderr);
  const inventoryText = readFileSync(output, 'utf8');
  const inventory = JSON.parse(inventoryText);
  assert.deepEqual(inventory, [
    { key: 'ENV_SECRET', source: 'github_environment_secret' },
    { key: 'ENV_VAR', source: 'github_environment_variable' },
    { key: 'REPO_SECRET', source: 'github_repository_secret' },
    { key: 'REPO_VAR', source: 'github_repository_variable' },
  ]);
  assert.equal(statSync(output).mode & 0o777, 0o600);
  assert.equal(inventoryText.includes('env-variable-must-not-leak'), false);
  assert.equal(inventoryText.includes('repo-variable-must-not-leak'), false);
  assert.equal(result.stdout.includes('variable-must-not-leak'), false);
});

test('organization inventory uses only configuration shared with the repository', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ores-sops-gh-org-inventory-'));
  const output = join(dir, 'inventory.json');
  const calls = join(dir, 'calls.txt');
  const bin = makeFakeGh(dir, String.raw`
${requirePinnedApiVersion}
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  *"orgs/ORESoftware/actions/"*)
    printf 'broad organization endpoint must not be used\n' >&2
    exit 93
    ;;
  *"repos/ORESoftware/example/actions/organization-secrets")
    printf '%s\n' '[{"secrets":[{"name":"ORG_SHARED_SECRET","updated_at":"ignored"}]}]'
    ;;
  *"repos/ORESoftware/example/actions/organization-variables")
    printf '%s\n' '[{"variables":[{"name":"ORG_SHARED_VAR","value":"org-variable-must-not-leak"}]}]'
    ;;
  *"repos/ORESoftware/example/actions/secrets")
    printf '%s\n' '[{"secrets":[]}]'
    ;;
  *"repos/ORESoftware/example/actions/variables")
    printf '%s\n' '[{"variables":[]}]'
    ;;
  *)
    printf 'unexpected endpoint\n' >&2
    exit 91
    ;;
esac`);

  const result = spawnSync(process.execPath, ['scripts/inventory-github-actions-config.mjs'], {
    cwd: new URL('..', import.meta.url),
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      CALLS: calls,
      ORES_SOPS_GHA_REPOSITORY: 'ORESoftware/example',
      ORES_SOPS_GHA_INCLUDE_ORGANIZATION: '1',
      ORES_SOPS_GHA_INVENTORY_FILE: output,
    },
    encoding: 'utf8',
  });

  assert.equal(result.status, 0, result.stderr);
  const inventoryText = readFileSync(output, 'utf8');
  assert.deepEqual(JSON.parse(inventoryText), [
    { key: 'ORG_SHARED_SECRET', source: 'github_organization_secret' },
    { key: 'ORG_SHARED_VAR', source: 'github_organization_variable' },
  ]);
  assert.equal(inventoryText.includes('org-variable-must-not-leak'), false);
  assert.equal(readFileSync(calls, 'utf8').includes('orgs/ORESoftware/actions/'), false);
});

test('GitHub API inventory suppresses gh stderr on failure', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ores-sops-gh-inventory-fail-'));
  const output = join(dir, 'inventory.json');
  const bin = makeFakeGh(dir, String.raw`
printf 'provider-response-with-sensitive-material\n' >&2
exit 7`);

  const result = spawnSync(process.execPath, ['scripts/inventory-github-actions-config.mjs'], {
    cwd: new URL('..', import.meta.url),
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      ORES_SOPS_GHA_REPOSITORY: 'ORESoftware/example',
      ORES_SOPS_GHA_INVENTORY_FILE: output,
    },
    encoding: 'utf8',
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /GitHub API inventory request failed/);
  assert.equal(result.stderr.includes('provider-response-with-sensitive-material'), false);
});

test('inventory output refuses a symlinked ancestor before recursive directory creation', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ores-sops-gh-inventory-symlink-'));
  const outside = join(dir, 'outside');
  const link = join(dir, 'redirect');
  mkdirSync(outside);
  symlinkSync(outside, link, 'dir');
  const output = join(link, 'created-through-symlink', 'inventory.json');
  const bin = makeFakeGh(dir, String.raw`
${requirePinnedApiVersion}
case "$*" in
  *"repos/ORESoftware/example/actions/secrets") printf '%s\n' '[{"secrets":[]}]' ;;
  *"repos/ORESoftware/example/actions/variables") printf '%s\n' '[{"variables":[]}]' ;;
  *) exit 91 ;;
esac`);

  const result = spawnSync(process.execPath, ['scripts/inventory-github-actions-config.mjs'], {
    cwd: new URL('..', import.meta.url),
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      ORES_SOPS_GHA_REPOSITORY: 'ORESoftware/example',
      ORES_SOPS_GHA_INVENTORY_FILE: output,
    },
    encoding: 'utf8',
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /must not traverse a symlink/);
  assert.equal(existsSync(join(outside, 'created-through-symlink')), false);
});
