import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { parseDotenv } from './github-actions-reconciliation.mjs';

function fail(message) {
  throw new Error(`ores-sops GitHub fallback push: ${message}`);
}

function requireEnv(name) {
  const value = process.env[name];
  if (!value) fail(`${name} is required`);
  return value;
}

function main() {
  const repository = requireEnv('ORES_SOPS_GHA_REPOSITORY');
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) fail('repository must be owner/name');
  const sourceFile = requireEnv('ORES_SOPS_GHA_PUSH_FILE');
  const scope = process.env.ORES_SOPS_GHA_SCOPE ?? 'repository';
  if (!['repository', 'environment'].includes(scope)) fail('scope must be repository or environment');
  const environment = scope === 'environment' ? requireEnv('ORES_SOPS_GHA_ENVIRONMENT') : undefined;
  if (environment && !['dev', 'stage', 'prod'].includes(environment)) fail('environment must be dev, stage, or prod');
  const values = parseDotenv(readFileSync(sourceFile, 'utf8'), 'GitHub fallback source');
  const apply = process.env.ORES_SOPS_GHA_APPLY === '1';

  for (const key of [...values.keys()].sort()) {
    if (!apply) {
      process.stdout.write(`ores-sops: dry-run GitHub fallback secret ${key} (${scope})\n`);
      continue;
    }
    const args = ['secret', 'set', key, '--repo', repository];
    if (environment) args.push('--env', environment);
    const result = spawnSync('gh', args, {
      input: values.get(key),
      encoding: 'utf8',
      stdio: ['pipe', 'ignore', 'ignore'],
    });
    if (result.error || result.status !== 0) fail(`GitHub API secret update failed for ${key}`);
    process.stdout.write(`ores-sops: updated GitHub fallback secret ${key} (${scope})\n`);
  }
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : 'ores-sops GitHub fallback push failed'}\n`);
  process.exitCode = 1;
}
