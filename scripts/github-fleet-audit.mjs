#!/usr/bin/env node

/**
 * Remote, keyless ores-sops fleet audit.
 *
 * This intentionally reads only repository metadata, path/mode information and
 * policy files. It never fetches ciphertext contents and never needs a SOPS or
 * age private identity.
 */

const API = 'https://api.github.com';
const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN || '';

function fail(message) {
  console.error(`ores-sops github fleet audit: ${message}`);
  process.exit(2);
}

function parseArgs(argv) {
  const out = {
    orgs: [],
    minRepos: 0,
    minOrgs: 0,
    maxPerOrg: 0,
    strict: false,
    json: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const value = (name) => {
      if (arg.startsWith(`${name}=`)) return arg.slice(name.length + 1);
      if (arg === name) {
        i += 1;
        if (i >= argv.length) fail(`${name} requires a value`);
        return argv[i];
      }
      return null;
    };

    let v;
    if ((v = value('--org')) !== null) out.orgs.push(v);
    else if ((v = value('--min-repos')) !== null) out.minRepos = Number(v);
    else if ((v = value('--min-orgs')) !== null) out.minOrgs = Number(v);
    else if ((v = value('--max-per-org')) !== null) out.maxPerOrg = Number(v);
    else if (arg === '--strict') out.strict = true;
    else if (arg === '--json') out.json = true;
    else if (arg === '--help' || arg === '-h') {
      console.log(`Usage: github-fleet-audit.mjs --org ORG [--org ORG...] [options]\n\nOptions:\n  --min-repos N       fail if fewer than N repositories are inspected\n  --min-orgs N        fail if fewer than N organizations are inspected\n  --max-per-org N     deterministic cap per org (0 = all)\n  --strict            fail on partial/conflicting adopted repositories\n  --json              emit JSON instead of TSV\n\nAuthentication: GH_TOKEN or GITHUB_TOKEN with read access to the target repos.`);
      process.exit(0);
    } else fail(`unknown argument: ${arg}`);
  }

  for (const [name, n] of [['--min-repos', out.minRepos], ['--min-orgs', out.minOrgs], ['--max-per-org', out.maxPerOrg]]) {
    if (!Number.isInteger(n) || n < 0) fail(`${name} must be a non-negative integer`);
  }
  out.orgs = [...new Set(out.orgs)].filter(Boolean);
  if (out.orgs.length === 0) fail('at least one --org is required');
  return out;
}

async function request(path, { optional404 = false } = {}) {
  const response = await fetch(`${API}${path}`, {
    headers: {
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'ores-sops-keyless-fleet-audit',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
  });
  if (optional404 && response.status === 404) return null;
  if (!response.ok) {
    const body = await response.text();
    throw new Error(`${response.status} ${response.statusText} for ${path}: ${body.slice(0, 240)}`);
  }
  return response.json();
}

async function listRepos(org) {
  const repos = [];
  for (let page = 1; ; page += 1) {
    const batch = await request(`/orgs/${encodeURIComponent(org)}/repos?type=all&sort=full_name&direction=asc&per_page=100&page=${page}`);
    repos.push(...batch.filter((repo) => !repo.archived && !repo.disabled));
    if (batch.length < 100) break;
  }
  return repos;
}

async function readText(repo, path) {
  const data = await request(`/repos/${repo.full_name}/contents/${path}?ref=${encodeURIComponent(repo.default_branch)}`, { optional404: true });
  if (data === null) return null;
  if (Array.isArray(data) || data.type !== 'file' || typeof data.content !== 'string') {
    throw new Error(`${repo.full_name}:${path} is not a regular contents-api file`);
  }
  return Buffer.from(data.content.replace(/\n/g, ''), 'base64').toString('utf8');
}

function exactRule(name) {
  return `^env/enc/${name}\\.env\\.enc$`;
}

function normalizeRule(raw) {
  const trimmed = raw.trim();
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function rulesFromPolicy(policy) {
  if (!policy) return [];
  const out = [];
  const re = /^\s*-\s*path_regex:\s*(.+?)\s*$/gm;
  for (const match of policy.matchAll(re)) out.push(normalizeRule(match[1]));
  return out;
}

function isSafeExample(path) {
  const base = path.split('/').at(-1);
  return base === '.env.example' || base === '.env.sample' || base === '.env.template';
}

function looksPlaintextEnv(path) {
  if (path === 'env/enc' || path.startsWith('env/enc/')) return false;
  if (isSafeExample(path)) return false;
  if (path === 'env/dec' || path.startsWith('env/dec/')) return true;
  const base = path.split('/').at(-1);
  return base === '.env' || base.endsWith('.env') || base.startsWith('.env.') || base.includes('.env.');
}

function isManagedPath(path) {
  return path === '.sops.yaml' || path === '.gitignore' || path === '.gitattributes' ||
    path === '.dockerignore' || path === 'justfile' || path === '.env' ||
    path === 'env' || path.startsWith('env/');
}

function hasLine(text, line) {
  return (text || '').split(/\r?\n/).some((candidate) => candidate.trim() === line);
}

async function auditRepo(repo) {
  const tree = await request(`/repos/${repo.full_name}/git/trees/${encodeURIComponent(repo.default_branch)}?recursive=1`);
  if (tree.truncated) {
    return { repo: repo.full_name, org: repo.owner.login, status: 'indeterminate', issues: ['recursive-tree-truncated'] };
  }

  const entries = new Map(tree.tree.map((entry) => [entry.path, entry]));
  const paths = [...entries.keys()];
  const policyEntry = entries.get('.sops.yaml');
  const encPaths = paths.filter((path) => path.startsWith('env/enc/'));
  const adoptedSignal = Boolean(policyEntry) || encPaths.length > 0;

  if (!adoptedSignal) {
    return { repo: repo.full_name, org: repo.owner.login, status: 'not-adopted', issues: [] };
  }

  const issues = [];
  const canonical = new Set(['env/enc/dev.env.enc', 'env/enc/prod.env.enc', 'env/enc/stage.env.enc']);

  for (const path of paths) {
    const entry = entries.get(path);
    if (isManagedPath(path) && entry?.mode === '120000') issues.push(`managed-symlink:${path}`);
    if (looksPlaintextEnv(path)) issues.push(`tracked-plaintext:${path}`);
  }
  for (const path of encPaths) {
    if (!canonical.has(path)) issues.push(`unexpected-ciphertext:${path}`);
    const entry = entries.get(path);
    if (entry && (entry.type !== 'blob' || entry.mode !== '100644')) issues.push(`ciphertext-mode:${path}:${entry.mode || entry.type}`);
  }

  if (!policyEntry) {
    issues.push('missing:.sops.yaml');
    return { repo: repo.full_name, org: repo.owner.login, status: 'partial', issues };
  }
  if (policyEntry.type !== 'blob' || policyEntry.mode !== '100644') issues.push(`policy-mode:.sops.yaml:${policyEntry.mode || policyEntry.type}`);

  const [policy, gitignore, gitattributes, dockerignore] = await Promise.all([
    readText(repo, '.sops.yaml'),
    readText(repo, '.gitignore'),
    readText(repo, '.gitattributes'),
    readText(repo, '.dockerignore'),
  ]);

  const rules = rulesFromPolicy(policy);
  const exactDev = exactRule('dev');
  const exactProd = exactRule('prod');
  const exactStage = exactRule('stage');
  if (rules.filter((r) => r === exactDev).length !== 1) issues.push('policy:dev-rule-not-exactly-once');
  if (rules.filter((r) => r === exactProd).length !== 1) issues.push('policy:prod-rule-not-exactly-once');
  if (rules.filter((r) => r === exactStage).length > 1) issues.push('policy:duplicate-stage-rule');
  for (const rule of rules) {
    if (rule.includes('env/enc') && ![exactDev, exactProd, exactStage].includes(rule)) issues.push(`policy:noncanonical-rule:${rule}`);
  }
  if ((policy || '').match(/^\s*-?\s*key_groups:\s*$/m)) issues.push('policy:key_groups-requires-threshold-review');
  if (entries.has('env/enc/stage.env.enc') && !rules.includes(exactStage)) issues.push('stage:ciphertext-without-exact-rule');

  if (!gitignore) issues.push('missing:.gitignore');
  else {
    if (!hasLine(gitignore, '/env/dec/') && !hasLine(gitignore, 'env/dec/')) issues.push('gitignore:missing-env-dec');
    if (!hasLine(gitignore, '/.env') && !hasLine(gitignore, '.env')) issues.push('gitignore:missing-root-env');
  }
  if (!gitattributes || !hasLine(gitattributes, '/env/enc/*.env.enc text eol=lf')) issues.push('gitattributes:missing-ciphertext-lf-rule');

  if (entries.has('Dockerfile')) {
    if (!dockerignore) issues.push('dockerignore:missing');
    else {
      const requiredDockerRules = [
        '.env',
        '.env.*',
        '**/*.env',
        '**/*.env.*',
        'env/dec',
        'env/dec/**',
        'env/enc',
        'env/enc/**',
        '**/*.pem',
        '**/*.key',
        '**/*.p8',
        '**/*service-account*.json',
      ];
      for (const line of requiredDockerRules) {
        if (!hasLine(dockerignore, line)) issues.push(`dockerignore:missing:${line}`);
      }
    }
  }

  const conflicting = issues.some((issue) =>
    issue.startsWith('tracked-plaintext:') ||
    issue.startsWith('unexpected-ciphertext:') ||
    issue.startsWith('managed-symlink:') ||
    issue.startsWith('policy:noncanonical-rule:') ||
    issue === 'policy:key_groups-requires-threshold-review' ||
    issue === 'stage:ciphertext-without-exact-rule'
  );
  return {
    repo: repo.full_name,
    org: repo.owner.login,
    status: conflicting ? 'conflicting' : issues.length ? 'partial' : 'adopted',
    issues,
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (!token) fail('GH_TOKEN or GITHUB_TOKEN is required for private-fleet coverage');

  const selected = [];
  for (const org of options.orgs) {
    const repos = await listRepos(org);
    const slice = options.maxPerOrg > 0 ? repos.slice(0, options.maxPerOrg) : repos;
    selected.push(...slice);
  }

  const results = [];
  for (const repo of selected) {
    try {
      results.push(await auditRepo(repo));
    } catch (error) {
      results.push({ repo: repo.full_name, org: repo.owner.login, status: 'indeterminate', issues: [`audit-error:${error.message}`] });
    }
  }

  const orgCount = new Set(results.map((r) => r.org)).size;
  const counts = Object.fromEntries(['adopted', 'not-adopted', 'partial', 'conflicting', 'indeterminate'].map((status) => [status, results.filter((r) => r.status === status).length]));
  const coverageOk = results.length >= options.minRepos && orgCount >= options.minOrgs;

  if (options.json) {
    console.log(JSON.stringify({ repositories: results.length, organizations: orgCount, counts, coverageOk, results }, null, 2));
  } else {
    console.log('status\trepository\tissues');
    for (const result of results) console.log(`${result.status}\t${result.repo}\t${result.issues.join(',') || '-'}`);
    console.error(`summary: repos=${results.length} orgs=${orgCount} adopted=${counts.adopted} not-adopted=${counts['not-adopted']} partial=${counts.partial} conflicting=${counts.conflicting} indeterminate=${counts.indeterminate}`);
  }

  if (!coverageOk) {
    console.error(`coverage floor failed: required repos>=${options.minRepos}, orgs>=${options.minOrgs}`);
    process.exit(3);
  }
  if (options.strict && (counts.partial > 0 || counts.conflicting > 0 || counts.indeterminate > 0)) process.exit(1);
}

main().catch((error) => fail(error.stack || error.message));
