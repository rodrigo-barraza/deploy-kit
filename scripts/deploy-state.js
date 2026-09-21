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
// A project in a subdirectory of a larger repository (registry `dir`) is its own
// directory plus its `sources`; the rest of that repository moving is not a change
// to it, so its sha is the last commit that touched those paths, not HEAD.
function repository(dir, cache, sources = []) {
  if (cache.has(dir)) return cache.get(dir);
  const nested = git(dir, 'rev-parse', '--show-prefix').toString().trim() !== '';
  const paths = ['.', ...(nested ? sources.map(source => `:(top)${source}`) : [])];
  const sha = (nested ? git(dir, 'log', '-1', '--format=%H', '--', ...paths) : git(dir, 'rev-parse', 'HEAD')).toString().trim();
  const diff = git(dir, 'diff', '--binary', '--no-ext-diff', 'HEAD', '--', ...paths);
  // Git lists an untracked nested repository (a worktree under .claude/worktrees, a
  // checkout dropped inside the tree) as `dir/`. It is not deployable source and
  // reading it as a file throws EISDIR, so it neither fingerprints nor dirties.
  const files = git(dir, 'ls-files', '--others', '--exclude-standard', '-z', '--', ...paths).toString().split('\0')
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
  const dir = path.join(root, project.dir || service);
  const repo = repository(dir, cache, project.sources || []);
  const libraries = {};
  for (const lib of libs) libraries[lib] = repository(path.join(root, lib), cache);
  const config = crypto.createHash('sha256').update(JSON.stringify({ project, device }));
  for (const file of [path.join(configDir, '.env.deploy'), path.join(kit, 'lib.sh'),
    path.join(kit, 'scripts/run-service.sh'), path.join(dir, '.env'), path.join(dir, 'vault.key')]) config.update(read(file));
  if (fs.existsSync(path.join(dir, 'boot.js'))) config.update(read(path.join(kit, 'templates/client-boot.js')));
  return { version: 2, service, target, sha: repo.sha, source: repo.fingerprint,
    config: config.digest('hex'), libraries, registry: hash(JSON.stringify(registry)) };
}
// Every way a snapshot can fail to match a receipt, worded for the console; an
// empty list is a match. A missing receipt is its own reason, not a mismatch: a
// service with no record deploys once to write one, which reads very
// differently from a service whose source moved.
const short = sha => (sha || '').slice(0, 7);
function differences(current, previous, impact = '', ignoreLibraries = false) {
  if (!previous) return ['no deployment record'];
  if (previous.version !== 2) return ['deployment record predates the current state format'];
  const reasons = [];
  if (current.service !== previous.service) reasons.push(`record belongs to ${previous.service}`);
  if (current.target !== previous.target) reasons.push(`last deployed to ${previous.target}`);
  if (current.source !== previous.source) {
    reasons.push(current.sha === previous.sha ? 'working tree changed' : `source ${short(previous.sha)} → ${short(current.sha)}`);
  }
  if (current.config !== previous.config) reasons.push('configuration changed');
  if (ignoreLibraries) return reasons;
  const before = previous.libraries || {};
  for (const id of new Set([...Object.keys(before), ...Object.keys(current.libraries)].sort())) {
    const old = before[id], lib = current.libraries[id];
    if (!old) reasons.push(`library ${id} not in the record`);
    else if (!lib) reasons.push(`library ${id} no longer required`);
    else if (old.fingerprint !== lib.fingerprint &&
      !(impact === 'unaffected' && !old.dirty && !lib.dirty && old.sha !== lib.sha)) {
      reasons.push(`library ${id} ${old.sha === lib.sha ? 'working tree changed' : `${short(old.sha)} → ${short(lib.sha)}`}`);
    }
  }
  return reasons;
}
function matches(current, previous, impact = '', ignoreLibraries = false) {
  return differences(current, previous, impact, ignoreLibraries).length === 0;
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
    // Exit 0 on a match. Otherwise exit 1 and print why on one line, so a caller
    // can show the reason (`reason=$(… matches …)`) or drop it (`>/dev/null`).
    let previous = null, reasons;
    if (fs.existsSync(options.previous)) {
      try { previous = json(options.previous); } catch { reasons = ['unreadable deployment record']; }
    }
    reasons ||= differences(json(options.current), previous, options.impact, options['ignore-libraries'] === 'true');
    if (reasons.length) process.stdout.write(reasons.join('; ') + '\n');
    process.exitCode = reasons.length ? 1 : 0;
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
module.exports = { snapshot, matches, differences, atomicWrite };
