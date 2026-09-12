#!/usr/bin/env node
// Content snapshots keep build reuse separate from confirmed rollouts. No secrets
// are stored: deployment configuration and ignored env files contribute hashes.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const read = file => fs.existsSync(file) ? fs.readFileSync(file) : Buffer.from('<missing>');
const json = file => JSON.parse(fs.readFileSync(file, 'utf8'));
function git(dir, ...args) {
  return execFileSync('git', ['-C', dir, ...args], { maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
}
function repository(dir, cache) {
  if (cache.has(dir)) return cache.get(dir);
  const sha = git(dir, 'rev-parse', 'HEAD').toString().trim();
  const diff = git(dir, 'diff', '--binary', '--no-ext-diff', 'HEAD', '--', '.');
  // Git lists an untracked nested repository (a worktree under .claude/worktrees, a
  // checkout dropped inside the tree) as `dir/`. It is not deployable source and
  // reading it as a file throws EISDIR, so it neither fingerprints nor dirties.
  const files = git(dir, 'ls-files', '--others', '--exclude-standard', '-z').toString().split('\0')
    .filter(file => file && !file.endsWith('/')).sort();
  const digest = crypto.createHash('sha256').update(sha).update(diff);
  for (const file of files) {
    const full = path.join(dir, file);
    digest.update(file).update('\0');
    digest.update(fs.lstatSync(full).isSymbolicLink() ? fs.readlinkSync(full) : fs.readFileSync(full));
  }
  const result = { sha, fingerprint: digest.digest('hex'), dirty: diff.length > 0 || files.length > 0 };
  cache.set(dir, result);
  return result;
}
function snapshot(root, kit, configDir, registry, service, libs, cache = new Map()) {
  const project = registry.projects.find(p => p.id === service);
  if (!project) throw new Error(`Unknown project: ${service}`);
  const target = project.deployTarget || 'synology';
  const device = (registry.devices || []).find(d => d.id === target);
  const dir = path.join(root, service);
  const repo = repository(dir, cache);
  const libraries = {};
  for (const lib of libs) libraries[lib] = repository(path.join(root, lib), cache);
  const config = crypto.createHash('sha256').update(JSON.stringify({ project, device }));
  for (const file of [path.join(configDir, '.env.deploy'), path.join(kit, 'lib.sh'),
    path.join(kit, 'scripts/run-service.sh'), path.join(dir, '.env'), path.join(dir, 'vault.key')]) config.update(read(file));
  if (fs.existsSync(path.join(dir, 'boot.js'))) config.update(read(path.join(kit, 'templates/client-boot.js')));
  return { version: 2, service, target, sha: repo.sha, source: repo.fingerprint,
    config: config.digest('hex'), libraries, registry: hash(JSON.stringify(registry)) };
}
function matches(current, previous, impact = '', ignoreLibraries = false) {
  if (!previous || previous.version !== 2 || current.service !== previous.service || current.target !== previous.target ||
      current.source !== previous.source || current.config !== previous.config) return false;
  if (ignoreLibraries) return true;
  if (JSON.stringify(Object.keys(current.libraries).sort()) !== JSON.stringify(Object.keys(previous.libraries || {}).sort())) return false;
  return Object.entries(current.libraries).every(([id, lib]) => {
    const old = previous.libraries[id];
    return old.fingerprint === lib.fingerprint ||
      (impact === 'unaffected' && !old.dirty && !lib.dirty && old.sha !== lib.sha);
  });
}
function atomicWrite(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.tmp`;
  try { fs.writeFileSync(temp, JSON.stringify(data, null, 2) + '\n', { mode: 0o600 }); fs.renameSync(temp, file); }
  finally { if (fs.existsSync(temp)) fs.unlinkSync(temp); }
}
function main(args) {
  const command = args.shift();
  const options = {};
  while (args.length) {
    const key = args.shift();
    if (!key.startsWith('--') || !args.length) throw new Error(`Invalid argument: ${key}`);
    options[key.slice(2)] = args.shift();
  }
  if (command === 'snapshot') {
    const registry = json(options.projects);
    const cache = new Map();
    const pairs = options.service ? [[options.service, options.libs || '']] :
      options.pairs.split(';').filter(Boolean).map(pair => pair.split(':'));
    for (const [service, libs] of pairs) {
      const data = snapshot(options.root, options.kit, options.config || options.kit, registry,
        service, (libs || '').split(/[ ,]+/).filter(Boolean), cache);
      atomicWrite(options.output || path.join(options.out, `${service}.json`), data);
    }
  } else if (command === 'matches') {
    let previous;
    try { previous = json(options.previous); } catch { process.exitCode = 1; return; }
    process.exitCode = matches(json(options.current), previous, options.impact, options['ignore-libraries'] === 'true') ? 0 : 1;
  } else if (command === 'record') {
    const data = json(options.input);
    if (options.image) data.image = options.image;
    if (options['tests-skipped'] !== undefined) data.testsSkipped = options['tests-skipped'] === 'true';
    if (options['unknown-libraries'] === 'true') data.libraries = {};
    atomicWrite(options.output, data);
  } else if (command === 'image') {
    try {
      const data = json(options.input);
      if (options['allow-untested'] !== 'false' || data.testsSkipped === false) process.stdout.write(data.image || '');
    } catch { /* no previous build */ }
  } else if (command === 'registry-matches') {
    try { process.exitCode = json(options.current).registry === json(options.previous).registry ? 0 : 1; }
    catch { process.exitCode = 1; }
  } else throw new Error(`Unknown state command: ${command}`);
}
if (require.main === module) {
  try { main(process.argv.slice(2)); }
  catch (err) { console.error(`Deployment state: ${err.message}`); process.exitCode = 2; }
}
module.exports = { snapshot, matches, atomicWrite };
