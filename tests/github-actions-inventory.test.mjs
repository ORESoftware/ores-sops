import assert from 'node:assert/strict';
import test from 'node:test';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
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

test('GitHub API inventory keeps names/source classes and discards variable values', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ores-sops-gh-inventory-'));
  const output = join(dir, 'inventory.json');
  const bin = makeFakeGh(dir, String.raw`
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
