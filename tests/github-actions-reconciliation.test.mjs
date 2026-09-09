import assert from 'node:assert/strict';
import test from 'node:test';
import {
  createOresOtelFallbackRecords,
  parseDotenv,
  reconcileGitHubActionsEnvironment,
  serializeDotenv,
} from '../scripts/github-actions-reconciliation.mjs';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const base = {
  repository: 'ORESoftware/example',
  environment: 'prod',
  authoritativePath: 'env/enc/prod.env.enc',
};

test('env/enc overrides an explicitly supplied GitHub secret value', () => {
  const result = reconcileGitHubActionsEnvironment({
    ...base,
    authoritative: parseDotenv('TOKEN=from-env-enc\nONLY_AUTH=yes\n'),
    fallbacks: [
      { source: 'github_repository_secret', values: { TOKEN: 'from-github', GITHUB_ONLY: 'fallback' } },
    ],
    inventory: [
      { key: 'TOKEN', source: 'github_repository_secret' },
      { key: 'GITHUB_ONLY', source: 'github_repository_secret' },
    ],
  });
  assert.equal(result.effective.get('TOKEN'), 'from-env-enc');
  assert.equal(result.effective.get('GITHUB_ONLY'), 'fallback');
  assert.deepEqual(result.receipt.observations, [{
    key: 'GITHUB_ONLY', githubSource: 'github_repository_secret', reason: 'missing_from_env_enc',
  }]);
});

test('GitHub inventory-only keys are observed without pretending their values are readable', () => {
  const result = reconcileGitHubActionsEnvironment({
    ...base,
    authoritative: { PRESENT: 'x' },
    inventory: [{ key: 'SECRET_NAME_ONLY', source: 'github_organization_secret' }],
  });
  assert.equal(result.effective.has('SECRET_NAME_ONLY'), false);
  assert.deepEqual(result.receipt.observations, [{
    key: 'SECRET_NAME_ONLY', githubSource: 'github_organization_secret', reason: 'missing_from_env_enc',
  }]);
});

test('GitHub fallback precedence is deterministic and env/enc still wins', () => {
  const result = reconcileGitHubActionsEnvironment({
    ...base,
    authoritative: { C: 'auth' },
    fallbacks: [
      // Deliberately shuffled: caller order must not alter contract precedence.
      { source: 'github_organization_secret', values: { A: 'organization', B: 'organization' } },
      { source: 'github_repository_secret', values: { A: 'repository', B: 'repository' } },
      { source: 'github_environment_secret', values: { A: 'environment', C: 'environment' } },
    ],
  });
  assert.deepEqual(Object.fromEntries(result.effective), { A: 'environment', B: 'repository', C: 'auth' });
});

test('receipt and ores-otel records never contain credential values or value-derived metadata', () => {
  const secret = 'super-sensitive-test-material';
  const result = reconcileGitHubActionsEnvironment({
    ...base,
    authoritative: { AUTH: 'authoritative-test-material' },
    fallbacks: [{ source: 'github_repository_secret', values: { FALLBACK: secret } }],
  });
  const telemetry = createOresOtelFallbackRecords(result.receipt, {
    timestamp: '2026-09-09T20:00:00.000Z', idPrefix: 'test',
  });
  const serialized = JSON.stringify({ receipt: result.receipt, telemetry });
  assert.equal(serialized.includes(secret), false);
  assert.equal(serialized.includes('authoritative-test-material'), false);
  assert.equal(serialized.includes('length'), false);
  assert.equal(serialized.includes('hash'), false);
  assert.equal(telemetry[0].schema, 'next-loggers/v1');
  assert.equal(telemetry[0].fields.key, 'FALLBACK');
});

test('duplicate or malformed dotenv keys fail closed', () => {
  assert.throws(() => parseDotenv('A=1\nA=2\n'), /duplicate key A/);
  assert.throws(() => parseDotenv('NOT-PORTABLE=x\n'), /portable dotenv identifier/);
  assert.throws(() => parseDotenv('missing-equals\n'), /malformed line/);
});

test('authoritative path must exactly match the selected environment', () => {
  assert.throws(() => reconcileGitHubActionsEnvironment({
    ...base,
    authoritativePath: 'env/enc/dev.env.enc',
    authoritative: {},
  }), /authoritativePath must be env\/enc\/prod\.env\.enc/);
});

test('dotenv serialization sorts keys and refuses multiline values', () => {
  assert.equal(serializeDotenv({ Z: 'last', A: 'first' }), 'A=first\nZ=last\n');
  assert.throws(() => serializeDotenv({ PEM: 'line1\nline2' }), /multiline/);
});

test('duplicate inventory entries collapse deterministically', () => {
  const result = reconcileGitHubActionsEnvironment({
    ...base,
    authoritative: {},
    inventory: [
      { key: 'A', source: 'github_repository_secret' },
      { key: 'A', source: 'github_repository_secret' },
      { key: 'A', source: 'github_repository_variable' },
    ],
  });
  assert.equal(result.receipt.observations.length, 2);
  assert.deepEqual(result.receipt.observations.map((item) => item.githubSource), [
    'github_repository_secret', 'github_repository_variable',
  ]);
});

test('runner writes private resolved output and value-blind ores-otel JSONL', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ores-sops-gha-'));
  const authoritativeFile = join(dir, 'authoritative.env');
  const fallbackFile = join(dir, 'fallback.env');
  const inventoryFile = join(dir, 'inventory.json');
  const manifestFile = join(dir, 'manifest.json');
  const resolvedFile = join(dir, 'resolved.env');
  const receiptFile = join(dir, 'receipt.json');
  const telemetryFile = join(dir, 'telemetry.jsonl');
  writeFileSync(authoritativeFile, 'TOKEN=authority\n');
  writeFileSync(fallbackFile, 'TOKEN=fallback\nONLY_GITHUB=hidden-test-value\n');
  writeFileSync(inventoryFile, JSON.stringify([
    { key: 'TOKEN', source: 'github_repository_secret' },
    { key: 'ONLY_GITHUB', source: 'github_repository_secret' },
  ]));
  writeFileSync(manifestFile, JSON.stringify({
    ...base,
    authoritativeFile,
    fallbacks: [{ source: 'github_repository_secret', path: fallbackFile }],
    inventoryFile,
    resolvedFile,
    receiptFile,
    telemetryFile,
  }));

  const result = spawnSync(process.execPath, ['scripts/run-github-actions-reconciliation.mjs'], {
    cwd: new URL('..', import.meta.url),
    env: { ...process.env, ORES_SOPS_GHA_RECONCILE_INPUT: manifestFile },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(resolvedFile, 'utf8'), 'ONLY_GITHUB=hidden-test-value\nTOKEN=authority\n');
  assert.equal(statSync(resolvedFile).mode & 0o777, 0o600);
  const publicEvidence = readFileSync(receiptFile, 'utf8') + readFileSync(telemetryFile, 'utf8');
  assert.equal(publicEvidence.includes('hidden-test-value'), false);
  assert.equal(publicEvidence.includes('authority'), false);
  assert.match(publicEvidence, /ONLY_GITHUB/);
  assert.match(publicEvidence, /next-loggers\/v1/);
});

test('duplicate fallback source is rejected instead of making order ambiguous', () => {
  assert.throws(() => reconcileGitHubActionsEnvironment({
    ...base,
    authoritative: {},
    fallbacks: [
      { source: 'github_repository_secret', values: { A: 'one' } },
      { source: 'github_repository_secret', values: { B: 'two' } },
    ],
  }), /duplicate fallback source/);
});

test('GitHub fallback push is dry-run by default and never emits values', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ores-sops-gh-push-dry-'));
  const source = join(dir, 'source.env');
  writeFileSync(source, 'SECRET_A=hidden-a\nSECRET_B=hidden-b\n');
  const result = spawnSync(process.execPath, ['scripts/push-github-actions-fallbacks.mjs'], {
    cwd: new URL('..', import.meta.url),
    env: {
      ...process.env,
      ORES_SOPS_GHA_REPOSITORY: 'ORESoftware/example',
      ORES_SOPS_GHA_PUSH_FILE: source,
    },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /SECRET_A/);
  assert.equal(result.stdout.includes('hidden-a'), false);
  assert.equal(result.stdout.includes('hidden-b'), false);
});

test('GitHub fallback push sends values only on stdin to gh secret set', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ores-sops-gh-push-'));
  const bin = join(dir, 'bin');
  mkdirSync(bin);
  const capture = join(dir, 'capture.txt');
  const fakeGh = join(bin, 'gh');
  writeFileSync(fakeGh, `#!/usr/bin/env bash\nset -euo pipefail\nprintf 'ARGS:%s\\n' \"$*\" >> \"$CAPTURE\"\nprintf 'STDIN:' >> \"$CAPTURE\"\ncat >> \"$CAPTURE\"\nprintf '\\n' >> \"$CAPTURE\"\n`);
  chmodSync(fakeGh, 0o755);
  const source = join(dir, 'source.env');
  writeFileSync(source, 'SECRET_A=hidden-a\n');
  const result = spawnSync(process.execPath, ['scripts/push-github-actions-fallbacks.mjs'], {
    cwd: new URL('..', import.meta.url),
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      CAPTURE: capture,
      ORES_SOPS_GHA_REPOSITORY: 'ORESoftware/example',
      ORES_SOPS_GHA_PUSH_FILE: source,
      ORES_SOPS_GHA_APPLY: '1',
      ORES_SOPS_GHA_SCOPE: 'environment',
      ORES_SOPS_GHA_ENVIRONMENT: 'prod',
    },
    encoding: 'utf8',
  });
  assert.equal(result.status, 0, result.stderr);
  const captured = readFileSync(capture, 'utf8');
  assert.match(captured, /ARGS:secret set SECRET_A --repo ORESoftware\/example --env prod/);
  assert.equal(captured.match(/hidden-a/g)?.length, 1);
  assert.equal(captured.split('\n')[0].includes('hidden-a'), false);
  assert.equal(result.stdout.includes('hidden-a'), false);
});
