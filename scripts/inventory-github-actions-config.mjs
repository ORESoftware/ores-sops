import {
  constants,
  closeSync,
  lstatSync,
  mkdirSync,
  openSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import { dirname, parse, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { GITHUB_SOURCES } from './github-actions-reconciliation.mjs';

const SOURCE_SET = new Set(GITHUB_SOURCES);
const KEY_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const GITHUB_API_VERSION = '2026-03-10';

function fail(message) {
  throw new Error(`ores-sops GitHub inventory: ${message}`);
}

function requireEnv(name) {
  const value = process.env[name];
  if (!value) fail(`${name} is required`);
  return value;
}

function parseRepository(repository) {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) fail('repository must be owner/name');
  const [owner, repo] = repository.split('/');
  return { owner, repo };
}

function assertNotSymlink(path, label) {
  try {
    if (lstatSync(path).isSymbolicLink()) fail(`${label} must not be a symlink`);
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
}

function assertNoSymlinkAncestors(path, label) {
  let current = resolve(path);
  const root = parse(current).root;
  while (current !== root) {
    try {
      const stat = lstatSync(current);
      if (stat.isSymbolicLink()) fail(`${label} must not traverse a symlink`);
      if (!stat.isDirectory()) fail(`${label} ancestor must be a directory`);
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    current = dirname(current);
  }
}

function writePrivateJson(path, value) {
  const absolute = resolve(path);
  const parent = dirname(absolute);
  // Check before mkdir so a repository-controlled ancestor symlink cannot
  // redirect recursive directory creation outside the intended private tree.
  assertNoSymlinkAncestors(parent, 'inventory output path');
  mkdirSync(parent, { recursive: true, mode: 0o700 });
  assertNoSymlinkAncestors(parent, 'inventory output path');
  assertNotSymlink(absolute, 'inventory output file');
  const temporary = `${absolute}.ores-sops-${process.pid}.tmp`;
  assertNotSymlink(temporary, 'inventory temporary file');
  let fd;
  try {
    fd = openSync(
      temporary,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
      0o600,
    );
    writeFileSync(fd, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
  renameSync(temporary, absolute);
}

function ghApi(endpoint) {
  const result = spawnSync(
    'gh',
    [
      'api',
      '--paginate',
      '--slurp',
      '-H',
      `X-GitHub-Api-Version: ${GITHUB_API_VERSION}`,
      endpoint,
    ],
    {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    },
  );
  if (result.error || result.status !== 0) fail('GitHub API inventory request failed');
  try {
    const parsed = JSON.parse(result.stdout);
    return Array.isArray(parsed) ? parsed : [parsed];
  } catch {
    fail('GitHub API returned invalid inventory JSON');
  }
}

function collect(entries, endpoint, collectionKey, source) {
  if (!SOURCE_SET.has(source)) fail('internal inventory source is unsupported');
  for (const page of ghApi(endpoint)) {
    const items = page?.[collectionKey];
    if (!Array.isArray(items)) fail(`GitHub API response omitted ${collectionKey}`);
    for (const item of items) {
      const key = item?.name;
      if (typeof key !== 'string' || !KEY_RE.test(key)) {
        fail('GitHub API returned a non-portable configuration key');
      }
      // Deliberately discard every other field. Variable endpoints return
      // values; secret endpoints return metadata. Neither belongs in evidence.
      entries.set(`${source}\u0000${key}`, { key, source });
    }
  }
}

function main() {
  const repository = requireEnv('ORES_SOPS_GHA_REPOSITORY');
  const { owner, repo } = parseRepository(repository);
  const outputFile = requireEnv('ORES_SOPS_GHA_INVENTORY_FILE');
  const environment = process.env.ORES_SOPS_GHA_ENVIRONMENT;
  if (environment && !['dev', 'stage', 'prod'].includes(environment)) {
    fail('environment must be dev, stage, or prod');
  }
  const includeOrganization = process.env.ORES_SOPS_GHA_INCLUDE_ORGANIZATION === '1';

  const entries = new Map();
  collect(entries, `repos/${owner}/${repo}/actions/secrets`, 'secrets', 'github_repository_secret');
  collect(entries, `repos/${owner}/${repo}/actions/variables`, 'variables', 'github_repository_variable');

  if (environment) {
    const encodedEnvironment = encodeURIComponent(environment);
    collect(
      entries,
      `repos/${owner}/${repo}/environments/${encodedEnvironment}/secrets`,
      'secrets',
      'github_environment_secret',
    );
    collect(
      entries,
      `repos/${owner}/${repo}/environments/${encodedEnvironment}/variables`,
      'variables',
      'github_environment_variable',
    );
  }

  if (includeOrganization) {
    // Repository-scoped endpoints return only organization configuration that
    // is actually shared with this repository. They avoid over-inventorying
    // unrelated org secrets/variables and require repository-level read access
    // rather than broad organization administration access.
    collect(
      entries,
      `repos/${owner}/${repo}/actions/organization-secrets`,
      'secrets',
      'github_organization_secret',
    );
    collect(
      entries,
      `repos/${owner}/${repo}/actions/organization-variables`,
      'variables',
      'github_organization_variable',
    );
  }

  const inventory = [...entries.values()].sort(
    (a, b) => a.key.localeCompare(b.key) || a.source.localeCompare(b.source),
  );
  writePrivateJson(outputFile, inventory);
  process.stdout.write(`ores-sops: inventoried GitHub Actions configuration names=${inventory.length}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : 'ores-sops GitHub inventory failed'}\n`);
  process.exitCode = 1;
}
