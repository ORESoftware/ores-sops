import { constants, closeSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import {
  createOresOtelFallbackRecords,
  parseDotenv,
  reconcileGitHubActionsEnvironment,
  serializeDotenv,
} from './github-actions-reconciliation.mjs';

function fail(message) {
  throw new Error(`ores-sops gha reconciliation runner: ${message}`);
}

function readJson(path, label) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    fail(`could not read valid ${label} JSON`);
  }
}

function assertNotSymlink(path, label) {
  try {
    if (lstatSync(path).isSymbolicLink()) fail(`${label} must not be a symlink`);
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
}

function writePrivateFile(path, contents) {
  const absolute = resolve(path);
  const parent = dirname(absolute);
  mkdirSync(parent, { recursive: true, mode: 0o700 });
  assertNotSymlink(parent, 'output directory');
  assertNotSymlink(absolute, 'output file');
  const temporary = `${absolute}.ores-sops-${process.pid}.tmp`;
  assertNotSymlink(temporary, 'temporary output file');
  let fd;
  try {
    fd = openSync(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    writeFileSync(fd, contents, 'utf8');
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
  renameSync(temporary, absolute);
}

function loadFallbacks(items) {
  if (!Array.isArray(items)) fail('fallbacks must be an array');
  return items.map((item) => {
    if (!item || typeof item !== 'object' || Array.isArray(item)) fail('fallback entry must be an object');
    if (typeof item.path !== 'string' || item.path === '') fail('fallback entry requires path');
    return {
      source: item.source,
      values: parseDotenv(readFileSync(item.path, 'utf8'), `${item.source} fallback`),
    };
  });
}

function main() {
  const manifestPath = process.env.ORES_SOPS_GHA_RECONCILE_INPUT;
  if (!manifestPath) fail('ORES_SOPS_GHA_RECONCILE_INPUT is required');
  const manifest = readJson(manifestPath, 'reconciliation manifest');
  const requiredStrings = [
    'repository', 'environment', 'authoritativePath', 'authoritativeFile',
    'resolvedFile', 'receiptFile', 'telemetryFile',
  ];
  for (const field of requiredStrings) {
    if (typeof manifest[field] !== 'string' || manifest[field] === '') fail(`manifest.${field} is required`);
  }
  const authoritative = parseDotenv(
    readFileSync(manifest.authoritativeFile, 'utf8'),
    'authoritative env/enc plaintext',
  );
  const inventory = manifest.inventoryFile
    ? readJson(manifest.inventoryFile, 'GitHub inventory')
    : (manifest.inventory ?? []);
  const { effective, receipt } = reconcileGitHubActionsEnvironment({
    repository: manifest.repository,
    environment: manifest.environment,
    authoritativePath: manifest.authoritativePath,
    authoritative,
    fallbacks: loadFallbacks(manifest.fallbacks ?? []),
    inventory,
  });
  const telemetry = createOresOtelFallbackRecords(receipt);
  writePrivateFile(manifest.resolvedFile, serializeDotenv(effective));
  writePrivateFile(manifest.receiptFile, `${JSON.stringify(receipt, null, 2)}\n`);
  writePrivateFile(manifest.telemetryFile, telemetry.map((record) => JSON.stringify(record)).join('\n') + (telemetry.length ? '\n' : ''));
  process.stdout.write(
    `ores-sops: reconciled GitHub Actions configuration; github-only observations=${receipt.observations.length}\n`,
  );
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : 'ores-sops gha reconciliation runner failed'}\n`);
  process.exitCode = 1;
}
