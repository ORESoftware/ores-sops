const ENVIRONMENTS = new Set(['dev', 'stage', 'prod']);

export const RECEIPT_SCHEMA = 'ores-sops.github-actions-reconciliation/v1';
export const ORES_OTEL_SCHEMA = 'next-loggers/v1';
export const GITHUB_SOURCES = Object.freeze([
  'github_environment_secret',
  'github_repository_secret',
  'github_organization_secret',
  'github_environment_variable',
  'github_repository_variable',
  'github_organization_variable',
]);
const GITHUB_SOURCE_SET = new Set(GITHUB_SOURCES);

const KEY_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const REPOSITORY_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

function fail(message) {
  throw new Error(`ores-sops gha reconciliation: ${message}`);
}

export function validateKey(key) {
  if (typeof key !== 'string' || !KEY_RE.test(key)) {
    fail('configuration key is not a portable dotenv identifier');
  }
  return key;
}

export function parseDotenv(text, label = 'dotenv') {
  if (typeof text !== 'string') fail(`${label} must be text`);
  const values = new Map();
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (line.trim() === '' || /^\s*#/.test(line)) continue;
    const equals = line.indexOf('=');
    if (equals <= 0) fail(`${label} contains malformed line ${index + 1}`);
    const key = validateKey(line.slice(0, equals));
    if (values.has(key)) fail(`${label} contains duplicate key ${key}`);
    values.set(key, line.slice(equals + 1));
  }
  return values;
}

function normalizeValueMap(input, label) {
  if (input instanceof Map) {
    const out = new Map();
    for (const [key, value] of input) {
      validateKey(key);
      if (typeof value !== 'string') fail(`${label} value for ${key} must be a string`);
      out.set(key, value);
    }
    return out;
  }
  if (input && typeof input === 'object' && !Array.isArray(input)) {
    return normalizeValueMap(new Map(Object.entries(input)), label);
  }
  fail(`${label} must be a Map or plain object`);
}

function normalizeInventory(inventory) {
  if (!Array.isArray(inventory)) fail('inventory must be an array');
  const seen = new Set();
  const result = [];
  for (const item of inventory) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) fail('inventory entry must be an object');
    const key = validateKey(item.key);
    const source = item.source;
    if (!GITHUB_SOURCE_SET.has(source)) fail(`unknown GitHub source for ${key}`);
    const identity = `${source}\u0000${key}`;
    if (seen.has(identity)) continue;
    seen.add(identity);
    result.push({ key, source });
  }
  return result.sort((a, b) => a.key.localeCompare(b.key) || a.source.localeCompare(b.source));
}

function validateContext({ repository, environment, authoritativePath }) {
  if (typeof repository !== 'string' || !REPOSITORY_RE.test(repository)) {
    fail('repository must be owner/name');
  }
  if (!ENVIRONMENTS.has(environment)) fail('environment must be dev, stage, or prod');
  const expected = `env/enc/${environment}.env.enc`;
  if (authoritativePath !== expected) fail(`authoritativePath must be ${expected}`);
}

export function reconcileGitHubActionsEnvironment({
  repository,
  environment,
  authoritativePath = `env/enc/${environment}.env.enc`,
  authoritative,
  fallbacks = [],
  inventory = [],
}) {
  validateContext({ repository, environment, authoritativePath });
  const authoritativeValues = normalizeValueMap(authoritative, 'authoritative env/enc');
  if (!Array.isArray(fallbacks)) fail('fallbacks must be an array');

  const effective = new Map();
  const fallbackSourceForKey = new Map();

  // GitHub fallback precedence is intrinsic to the contract, not caller order.
  // That prevents a workflow from accidentally making an organization-level
  // value outrank a repository/environment value. env/enc is applied last and
  // always wins overall.
  const fallbackBySource = new Map();
  for (const fallback of fallbacks) {
    if (!fallback || typeof fallback !== 'object' || Array.isArray(fallback)) fail('fallback entry must be an object');
    if (!GITHUB_SOURCE_SET.has(fallback.source)) fail('fallback source is not supported');
    if (fallbackBySource.has(fallback.source)) fail(`duplicate fallback source ${fallback.source}`);
    fallbackBySource.set(
      fallback.source,
      normalizeValueMap(fallback.values, `${fallback.source} fallback`),
    );
  }
  for (const source of GITHUB_SOURCES) {
    const values = fallbackBySource.get(source);
    if (!values) continue;
    for (const [key, value] of values) {
      if (!effective.has(key)) {
        effective.set(key, value);
        fallbackSourceForKey.set(key, source);
      }
    }
  }

  for (const [key, value] of authoritativeValues) effective.set(key, value);

  const normalizedInventory = normalizeInventory(inventory);
  const observedSourcesByKey = new Map();
  for (const { key, source } of normalizedInventory) {
    if (!observedSourcesByKey.has(key)) observedSourcesByKey.set(key, []);
    observedSourcesByKey.get(key).push(source);
  }
  for (const [key, source] of fallbackSourceForKey) {
    if (!observedSourcesByKey.has(key)) observedSourcesByKey.set(key, []);
    if (!observedSourcesByKey.get(key).includes(source)) observedSourcesByKey.get(key).push(source);
  }

  const decisions = [...effective.keys()].sort().map((key) => {
    if (authoritativeValues.has(key)) {
      const decision = { key, resolution: 'env_enc' };
      const source = fallbackSourceForKey.get(key) ?? observedSourcesByKey.get(key)?.[0];
      if (source) decision.githubSource = source;
      return decision;
    }
    return {
      key,
      resolution: 'github_fallback',
      githubSource: fallbackSourceForKey.get(key),
    };
  });

  const observationMap = new Map();
  for (const [key, sources] of observedSourcesByKey) {
    if (authoritativeValues.has(key)) continue;
    for (const source of sources.sort()) {
      observationMap.set(`${key}\u0000${source}`, {
        key,
        githubSource: source,
        reason: 'missing_from_env_enc',
      });
    }
  }
  const observations = [...observationMap.values()].sort(
    (a, b) => a.key.localeCompare(b.key) || a.githubSource.localeCompare(b.githubSource),
  );

  return {
    effective,
    receipt: {
      schema: RECEIPT_SCHEMA,
      repository,
      environment,
      authoritativePath,
      decisions,
      observations,
    },
  };
}

export function serializeDotenv(values) {
  const normalized = normalizeValueMap(values, 'resolved environment');
  return [...normalized.keys()]
    .sort()
    .map((key) => {
      const value = normalized.get(key);
      if (value.includes('\0') || value.includes('\r') || value.includes('\n')) {
        fail(`resolved value for ${key} is multiline; use a file/secret-file transport instead of dotenv`);
      }
      return `${key}=${value}`;
    })
    .join('\n') + '\n';
}

function safeTimestamp(timestamp) {
  if (typeof timestamp !== 'string' || !Number.isFinite(Date.parse(timestamp))) {
    fail('telemetry timestamp must be RFC3339-compatible');
  }
  return timestamp;
}

export function createOresOtelFallbackRecords(
  receipt,
  { timestamp = new Date().toISOString(), idPrefix = 'ores-sops-gha' } = {},
) {
  if (!receipt || receipt.schema !== RECEIPT_SCHEMA) fail('cannot emit telemetry for an unknown receipt');
  safeTimestamp(timestamp);
  return receipt.observations.map((observation, index) => ({
    schema: ORES_OTEL_SCHEMA,
    id: `${idPrefix}-${index + 1}`,
    timestamp,
    level: 'WARN',
    runtime: 'node',
    appName: 'ores-sops',
    name: 'ores.config.github_fallback',
    message: 'GitHub Actions configuration key is absent from authoritative env/enc',
    values: [],
    fields: {
      event: 'ores.config.github_fallback',
      repository: receipt.repository,
      environment: receipt.environment,
      key: observation.key,
      githubSource: observation.githubSource,
      authoritativeSource: 'env/enc',
      reason: observation.reason,
    },
    tags: ['ores-sops', 'github-actions', 'config-drift'],
  }));
}
