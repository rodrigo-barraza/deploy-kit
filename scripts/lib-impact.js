// ============================================================
// Library Impact Analysis
//
// Decides, per service, whether library changes since that
// service's last deploy actually touch anything the service
// imports. Replaces the coarse "library SHA moved → rebuild
// every consumer" rule in deploy-all.sh with symbol-level
// precision:
//
//   changed lib files
//     → internal import-graph closure (what else is affected)
//     → dirty export surface (subpaths + barrel symbols + css)
//     → intersect with each consumer's actual imports
//
// Cross-library propagation is handled too: if utilities-library
// changes a symbol that components-library uses inside
// ButtonComponent, every client importing ButtonComponent is
// affected even without importing the utilities symbol directly.
//
// FAIL-OPEN PHILOSOPHY: any situation the analysis cannot map
// confidently (package.json changes, deleted src files, dist
// drift without src changes, unparseable imports, unknown
// subpaths, git errors) resolves to "affected" — worst case we
// rebuild something unnecessarily, never the reverse.
//
// Usage (normally invoked by deploy-all.sh):
//   node scripts/lib-impact.js \
//     --root <workspace-root> \
//     --state <deploy-state-dir> \
//     --projects <projects.json> \
//     --pairs "svc1:libA,libB;svc2:libA"
//
// Debug helpers:
//   --human                        readable report instead of bash eval output
//   --override-base lib=<sha>      analyze lib as if every service was last
//                                  built at <sha> (repeatable; for testing)
//
// Output (stdout, bash-eval'able):
//   IMPACT_SCRIPT_OK=true
//   IMPACT_VERDICT[<svc>]='affected' | 'unaffected' | 'none'
//   IMPACT_REASON[<svc>]='<short human reason>'
// Summary lines for the terminal go to stderr.
// ============================================================

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// ── CLI parsing ───────────────────────────────────────────────
const args = process.argv.slice(2);
function argValue(flag) {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : null;
}
const ROOT_DIR = argValue('--root');
const STATE_DIR = argValue('--state');
const PROJECTS_JSON = argValue('--projects');
const PAIRS_ARG = argValue('--pairs') || '';
const HUMAN_MODE = args.includes('--human');
const OVERRIDE_BASES = {};
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--override-base' && args[i + 1] && args[i + 1].includes('=')) {
    const [lib, sha] = args[i + 1].split('=');
    OVERRIDE_BASES[lib] = sha;
  }
}

if (!ROOT_DIR || !STATE_DIR || !PAIRS_ARG) {
  console.error('Usage: lib-impact.js --root <dir> --state <dir> --projects <json> --pairs "svc:lib1,lib2;..."');
  process.exit(1);
}

// ── Per-project overrides from projects.json ──────────────────
// "libImpact": "all" on a project = any library change rebuilds it
// (e.g. portal-client, whose prebuild codegen catalogs the entire
// library surface regardless of what it imports).
const projectOverrides = {};
try {
  const config = JSON.parse(fs.readFileSync(PROJECTS_JSON, 'utf8'));
  for (const project of config.projects || []) {
    if (project.libImpact) projectOverrides[project.id] = project.libImpact;
  }
} catch (err) { /* overrides are optional; absence is fine */ }

// ── Parse service:lib pairs ───────────────────────────────────
// deploy-all.sh owns pair enumeration (from SVC_LIB_DEPS); this
// script owns verdicts. Format: "svc1:libA,libB;svc2:libA"
const servicePairs = new Map(); // svc -> [libId, ...]
for (const chunk of PAIRS_ARG.split(';')) {
  if (!chunk.trim()) continue;
  const [svc, libsCsv] = chunk.split(':');
  if (!svc || !libsCsv) continue;
  servicePairs.set(svc.trim(), libsCsv.split(',').map(s => s.trim()).filter(Boolean));
}

// ── git helper ────────────────────────────────────────────────
function git(dir, ...gitArgs) {
  return execFileSync('git', ['-C', dir, ...gitArgs], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: 32 * 1024 * 1024,
  });
}

// ── Comment stripping (for import scanning only) ──────────────
// Removes /* */ blocks and // line comments so doc examples like
// " * import { X } from '@rodrigo-barraza/...' " don't register
// as real imports. Heuristic (doesn't parse strings) but safe for
// import detection: package specifiers never contain "//".
function stripComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/(^|[\s;,{}()])\/\/[^\n]*/g, '$1');
}

// ── File walking ──────────────────────────────────────────────
const CODE_EXT = /\.(tsx?|jsx?|mjs|cjs)$/;
function walkCodeFiles(dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'node_modules' || entry.name === '.git' || entry.name === 'dist') continue;
      walkCodeFiles(full, out);
    } else if (CODE_EXT.test(entry.name) && !/\.test\.|\.spec\./.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

// ── Relative import resolution ────────────────────────────────
// Handles the workspace conventions: explicit ".ts" extensions
// (utilities-library), ".js" extensions that map to .ts/.tsx
// sources (components-library), extensionless, and index files.
function resolveRelative(fromFile, spec) {
  const base = path.resolve(path.dirname(fromFile), spec);
  const candidates = [
    base,
    base.replace(/\.js$/, '.ts'), base.replace(/\.js$/, '.tsx'),
    base + '.ts', base + '.tsx', base + '.js',
    path.join(base, 'index.ts'), path.join(base, 'index.tsx'), path.join(base, 'index.js'),
  ];
  for (const candidate of candidates) {
    try { if (fs.statSync(candidate).isFile()) return candidate; } catch { /* keep trying */ }
  }
  return null;
}

// ── Import statement extraction ───────────────────────────────
// Captures: import ... from "x" / export ... from "x" /
// import("x") / require("x") / bare side-effect import "x".
// Returns [{clause, spec}] where clause is the binding text
// ("" for side-effect / dynamic / require).
function extractImports(source) {
  const results = [];
  // Clause is restricted to quote/semicolon-free text so a bare
  // side-effect import can never be swallowed into the clause of a
  // later `from "..."` statement (binding clauses contain neither).
  const fromRe = /(?:import|export)\s+([^'";]*?)\s*from\s*['"]([^'"]+)['"]/g;
  const bareRe = /import\s*['"]([^'"]+)['"]/g;
  const dynRe = /(?:import\s*\(|require\s*\()\s*['"]([^'"]+)['"]/g;
  let match;
  while ((match = fromRe.exec(source))) results.push({ clause: match[1].trim(), spec: match[2] });
  while ((match = bareRe.exec(source))) results.push({ clause: '', spec: match[1] });
  while ((match = dynRe.exec(source))) results.push({ clause: '', spec: match[1] });
  return results;
}

// Parse named bindings out of an import/export clause.
// "{ a, b as c, type D }, defaultName" → { symbols:[a,b,D,default], wildcard:false }
// "* as ns" → { wildcard: true }
function parseClause(clause) {
  if (!clause) return { symbols: [], wildcard: true }; // side-effect/dynamic/require → whole surface
  // Statement-level type modifier: `import type { X }` / `export type { X }`
  // leaves the word "type" outside the braces — strip it so it isn't
  // misread as a default-import binding.
  clause = clause.replace(/^type\s+(?=[{*])/, '');
  if (/\*\s*(as\s+\S+)?/.test(clause) && !clause.includes('{')) return { symbols: [], wildcard: true };
  const symbols = [];
  const braced = clause.match(/\{([^}]*)\}/);
  if (braced) {
    for (const raw of braced[1].split(',')) {
      const piece = raw.trim().replace(/^type\s+/, '');
      if (!piece) continue;
      // "orig as alias" → the ORIGINAL name is the library-side symbol
      const original = piece.split(/\s+as\s+/)[0].trim();
      if (original) symbols.push(original === 'default' ? 'default' : original);
    }
  }
  // A default import outside braces ("Foo, { a }" or just "Foo")
  const withoutBraces = clause.replace(/\{[^}]*\}/, '').replace(/,/g, ' ').trim();
  if (withoutBraces && !withoutBraces.startsWith('*')) symbols.push('default');
  return { symbols, wildcard: false };
}

// ── Barrel source parsing (shared by current + historical) ────
// Returns { specBySymbol: Map(exportedName -> raw spec),
//           opaque: bool (contains `export *`),
//           residue: source minus re-export statements, whitespace-
//                    collapsed — used to detect inline (non-re-export)
//                    code changes in the barrel itself }
function parseBarrelSource(rawSource) {
  const source = stripComments(rawSource);
  const specBySymbol = new Map();
  const opaque = /export\s*\*\s*from/.test(source);
  const reExportRe = /export\s+(?:type\s+)?\{([^}]+)\}\s*from\s*['"]([^'"]+)['"]\s*;?/g;
  let match;
  while ((match = reExportRe.exec(source))) {
    for (const raw of match[1].split(',')) {
      const piece = raw.trim().replace(/^type\s+/, '');
      if (!piece) continue;
      // "orig as Exported" → consumers import the EXPORTED name
      const parts = piece.split(/\s+as\s+/);
      const exportedName = (parts[1] || parts[0]).trim();
      if (exportedName) specBySymbol.set(exportedName, match[2]);
    }
  }
  const residue = source.replace(reExportRe, ' ').replace(/\s+/g, ' ').trim();
  return { specBySymbol, opaque, residue };
}

// ══════════════════════════════════════════════════════════════
// LIBRARY MODEL
// Everything the analysis needs to know about one library:
// import graph, barrel symbol map, subpath entry map, css exports.
// ══════════════════════════════════════════════════════════════
const libraryModels = new Map(); // libId -> model | null (missing dir)

function buildLibraryModel(libId) {
  if (libraryModels.has(libId)) return libraryModels.get(libId);
  const libDir = path.join(ROOT_DIR, libId);
  if (!fs.existsSync(path.join(libDir, 'package.json'))) {
    libraryModels.set(libId, null);
    return null;
  }

  const pkg = JSON.parse(fs.readFileSync(path.join(libDir, 'package.json'), 'utf8'));
  const packageName = pkg.name; // e.g. @rodrigo-barraza/utilities-library
  const srcDir = path.join(libDir, 'src');
  const files = walkCodeFiles(srcDir);

  // ── Internal import graph (relative imports only — verified:
  //    neither library uses tsconfig path aliases) ──
  const importersOf = new Map(); // file -> Set(files importing it)
  const crossLibUsage = new Map(); // file -> Map(otherLibPkgName -> {symbols:Set, subpaths:Set, wildcard})
  for (const file of files) {
    let source;
    try { source = stripComments(fs.readFileSync(file, 'utf8')); } catch { continue; }
    for (const { clause, spec } of extractImports(source)) {
      if (spec.startsWith('.')) {
        const resolved = resolveRelative(file, spec);
        if (resolved) {
          if (!importersOf.has(resolved)) importersOf.set(resolved, new Set());
          importersOf.get(resolved).add(file);
        }
        // Unresolved relative import inside the lib: the importing file
        // itself would fail to build; nothing extra to propagate.
      } else if (spec.startsWith('@rodrigo-barraza/')) {
        // Cross-library import — recorded for two-hop propagation
        const slash = spec.indexOf('/', '@rodrigo-barraza/'.length);
        const otherPkg = slash === -1 ? spec : spec.slice(0, slash);
        const subpath = slash === -1 ? null : '.' + spec.slice(slash);
        if (otherPkg === packageName) continue; // self-reference (docs only)
        if (!crossLibUsage.has(file)) crossLibUsage.set(file, new Map());
        const perPkg = crossLibUsage.get(file);
        if (!perPkg.has(otherPkg)) perPkg.set(otherPkg, { symbols: new Set(), subpaths: new Set(), wildcard: false });
        const usage = perPkg.get(otherPkg);
        if (subpath) usage.subpaths.add(subpath);
        else {
          const { symbols, wildcard } = parseClause(clause);
          if (wildcard) usage.wildcard = true;
          symbols.forEach(s => usage.symbols.add(s));
        }
      }
    }
  }

  // Reverse-transitive closure: given a changed file, every file
  // whose behavior can change (itself + importers, recursively).
  function affectedClosure(seedFiles) {
    const seen = new Set(seedFiles);
    const stack = [...seedFiles];
    while (stack.length) {
      const current = stack.pop();
      for (const importer of importersOf.get(current) || []) {
        if (!seen.has(importer)) { seen.add(importer); stack.push(importer); }
      }
    }
    return seen;
  }

  // ── Barrel: exported symbol -> defining file ──
  // Both libraries use explicit named re-exports (no `export *`
  // today — if one ever appears, `barrelOpaque` makes any change
  // to files the barrel imports dirty ALL root symbols).
  const barrelPath = [path.join(srcDir, 'index.ts'), path.join(srcDir, 'index.tsx')]
    .find(p => fs.existsSync(p)) || null;
  const barrelSymbolToFile = new Map();
  const barrelSymbolToSpec = new Map(); // raw import spec (for old-vs-new barrel diffs)
  let barrelOpaque = false;
  let barrelResidue = '';
  if (barrelPath) {
    const parsed = parseBarrelSource(fs.readFileSync(barrelPath, 'utf8'));
    barrelOpaque = parsed.opaque;
    barrelResidue = parsed.residue;
    for (const [symbol, spec] of parsed.specBySymbol) {
      barrelSymbolToSpec.set(symbol, spec);
      const target = resolveRelative(barrelPath, spec);
      if (target) barrelSymbolToFile.set(symbol, target);
    }
  }

  // ── Subpath exports: "./service/mongo" -> src entry file ──
  // package.json exports point at dist/; map back to the src twin.
  const subpathToEntry = new Map();
  const cssExportPatterns = []; // e.g. { subpathGlob: "./*.css", target: "./src/styles/*.css" }
  for (const [subpath, target] of Object.entries(pkg.exports || {})) {
    const targetPath = typeof target === 'string' ? target : (target.import || target.default || target.types);
    if (!targetPath) continue;
    if (subpath.includes('*')) {
      cssExportPatterns.push({ subpath, target: targetPath });
      continue;
    }
    const rel = targetPath.replace(/^\.\/dist\//, '').replace(/\.d\.ts$/, '').replace(/\.js$/, '');
    const base = path.join(srcDir, rel);
    const entry = [base + '.ts', base + '.tsx', path.join(base, 'index.ts'), path.join(base, 'index.tsx')]
      .find(c => { try { return fs.statSync(c).isFile(); } catch { return false; } });
    if (entry) subpathToEntry.set(subpath, entry);
  }

  const model = {
    libId, libDir, srcDir, packageName, files,
    importersOf, crossLibUsage, affectedClosure,
    barrelPath, barrelSymbolToFile, barrelSymbolToSpec, barrelOpaque, barrelResidue,
    subpathToEntry, cssExportPatterns,
  };
  libraryModels.set(libId, model);
  return model;
}

// ══════════════════════════════════════════════════════════════
// CHANGED FILES → DIRTY SURFACE
// ══════════════════════════════════════════════════════════════

// Path classification for changed library files.
// Only content that ships to consumers matters: src/**, dist/**,
// and package.json (exports map + dependency versions). Everything
// else (tests, docs, lockfile, configs, hooks) affects the library's
// own dev loop, not what consumers install from the committed tree.
const IGNORE_RE = new RegExp([
  '(^|/)README', '\\.md$', '\\.log$', '^\\.git(ignore|attributes)$',
  '^tests?/', '(^|/)__tests__/', '\\.test\\.', '\\.spec\\.',
  '^docs/', '^\\.github/', '^\\.githooks/', '^scripts/',
  '\\.tsbuildinfo$', '\\.map$', '^\\.env', '^eslint\\.config\\.', '^vitest\\.config\\.',
  '^\\.prettierrc', '^pnpm-lock\\.yaml$', '^package-lock\\.json$', '^pnpm-workspace\\.yaml$', '^tsconfig\\.json$',
].join('|'));

// Compute the dirty export surface of a library relative to a base
// SHA. Memoized per (lib, base) — most services share one base.
const surfaceCache = new Map(); // `${libId}@${base}` -> surface
function computeSurface(libId, baseSha) {
  const cacheKey = `${libId}@${baseSha}`;
  if (surfaceCache.has(cacheKey)) return surfaceCache.get(cacheKey);
  const model = buildLibraryModel(libId);
  const surface = {
    all: false, reason: '',
    changedCount: 0, changedSample: [],
    rootSymbols: new Set(), subpaths: new Set(), cssFiles: new Set(),
    affectedFiles: new Set(),
  };
  const finish = () => { surfaceCache.set(cacheKey, surface); return surface; };
  const failOpen = (reason) => { surface.all = true; surface.reason = reason; return finish(); };

  if (!model) return failOpen('library directory missing');

  // git diff <base> = base vs WORKTREE (committed + staged + unstaged),
  // which matches what has_changes() considers "changed". Untracked
  // files are appended separately.
  let statusLines;
  try {
    statusLines = git(model.libDir, 'diff', '--name-status', '--no-renames', baseSha)
      .split('\n').filter(Boolean).map(line => {
        const [status, ...rest] = line.split('\t');
        return { status: status.trim(), file: rest.join('\t') };
      });
    for (const untracked of git(model.libDir, 'ls-files', '--others', '--exclude-standard').split('\n').filter(Boolean)) {
      statusLines.push({ status: 'A', file: untracked });
    }
  } catch (err) {
    return failOpen(`git diff vs ${baseSha.slice(0, 7)} failed (rebased/gc'd base?)`);
  }

  const dirtySrcFiles = [];
  let distChanged = false;
  let srcChanged = false;
  for (const { status, file } of statusLines) {
    if (IGNORE_RE.test(file)) continue;
    if (file.startsWith('dist/')) { distChanged = true; continue; }
    if (file === 'package.json') return failOpen('package.json changed (deps/exports — conservative rebuild)');
    if (file.startsWith('src/')) {
      srcChanged = true;
      if (status === 'D') return failOpen(`src file deleted (${file})`);
      const absolute = path.join(model.libDir, file);
      dirtySrcFiles.push(absolute);
      surface.changedCount++;
      if (surface.changedSample.length < 4) surface.changedSample.push(path.basename(file));
      continue;
    }
    // Anything else changed at the repo root we don't recognize —
    // classify conservatively rather than guess.
    return failOpen(`unclassified change (${file})`);
  }

  // dist/ is committed (built by the pre-commit hook), so real
  // changes always have a src twin. dist drift WITHOUT src changes
  // means hand-edits or toolchain drift → conservative rebuild.
  if (distChanged && !srcChanged) return failOpen('dist/ changed without src/ changes');

  if (dirtySrcFiles.length === 0) return finish(); // nothing consumer-visible

  // Closure + surface mapping
  const affected = model.affectedClosure(dirtySrcFiles);
  surface.affectedFiles = affected;

  // A direct edit to the barrel is compared old-vs-new: symbols that
  // were REMOVED or REMAPPED to a different file are dirty; purely
  // ADDED exports cannot affect existing consumers and are ignored.
  // (This keeps the everyday "add component + export it" flow from
  // rebuilding every client.) The barrel merely APPEARING in the
  // closure is expected for every export and is handled per-symbol
  // below. If the old barrel can't be read/parsed, or the barrel's
  // inline (non-re-export) code changed, fail open to all symbols.
  const barrelEditedDirectly = model.barrelPath && dirtySrcFiles.includes(model.barrelPath);
  if (barrelEditedDirectly) {
    let oldParsed = null;
    try {
      const relBarrel = path.relative(model.libDir, model.barrelPath).replace(/\\/g, '/');
      oldParsed = parseBarrelSource(git(model.libDir, 'show', `${baseSha}:${relBarrel}`));
    } catch { /* barrel didn't exist at base or git failed */ }
    if (!oldParsed || oldParsed.opaque || model.barrelOpaque || oldParsed.residue !== model.barrelResidue) {
      for (const symbol of model.barrelSymbolToFile.keys()) surface.rootSymbols.add(symbol);
      surface.rootSymbols.add('*'); // "everything incl. symbols we can't map"
    } else {
      for (const [symbol, oldSpec] of oldParsed.specBySymbol) {
        const newSpec = model.barrelSymbolToSpec.get(symbol);
        if (newSpec === undefined || newSpec !== oldSpec) surface.rootSymbols.add(symbol);
      }
    }
  } else if (model.barrelOpaque && affected.size > 0) {
    for (const symbol of model.barrelSymbolToFile.keys()) surface.rootSymbols.add(symbol);
  }
  for (const [symbol, definingFile] of model.barrelSymbolToFile) {
    if (affected.has(definingFile)) surface.rootSymbols.add(symbol);
  }
  for (const [subpath, entry] of model.subpathToEntry) {
    if (affected.has(entry)) surface.subpaths.add(subpath);
  }
  for (const file of affected) {
    if (file.endsWith('.css')) surface.cssFiles.add(file);
  }
  return finish();
}

// ── Two-hop: surface induced on lib M by changes in lib L ─────
// components-library imports utilities-library; a dirty utilities
// surface seeds the components files that use it, and the closure
// of those seeds dirties components' own export surface for clients.
const inducedCache = new Map(); // `${mId}<-${lId}@${base}` -> surface-like
function computeInducedSurface(dependentLibId, sourceLibId, sourceBase) {
  const cacheKey = `${dependentLibId}<-${sourceLibId}@${sourceBase}`;
  if (inducedCache.has(cacheKey)) return inducedCache.get(cacheKey);
  const dependent = buildLibraryModel(dependentLibId);
  const sourceModel = buildLibraryModel(sourceLibId);
  const induced = { all: false, rootSymbols: new Set(), subpaths: new Set(), seeds: [] };
  const finish = () => { inducedCache.set(cacheKey, induced); return induced; };
  if (!dependent || !sourceModel) return finish();

  const sourceSurface = computeSurface(sourceLibId, sourceBase);
  if (sourceSurface.all) { induced.all = true; return finish(); }

  // Which dependent-lib files import an affected part of the source lib?
  const seeds = [];
  for (const [file, perPkg] of dependent.crossLibUsage) {
    const usage = perPkg.get(sourceModel.packageName);
    if (!usage) continue;
    if (usageHitsSurface(usage, sourceSurface, sourceModel)) seeds.push(file);
  }
  if (seeds.length === 0) return finish();
  induced.seeds = seeds.map(f => path.basename(f));

  const affected = dependent.affectedClosure(seeds);
  if (dependent.barrelOpaque) { induced.all = true; return finish(); }
  for (const [symbol, definingFile] of dependent.barrelSymbolToFile) {
    if (affected.has(definingFile)) induced.rootSymbols.add(symbol);
  }
  for (const [subpath, entry] of dependent.subpathToEntry) {
    if (affected.has(entry)) induced.subpaths.add(subpath);
  }
  return finish();
}

// ── Does a usage record hit a dirty surface? ──────────────────
// usage: { symbols:Set, subpaths:Set, wildcard:bool, cssFiles:Set? }
function usageHitsSurface(usage, surface, model) {
  if (surface.all) return true;
  if (usage.wildcard && (surface.rootSymbols.size > 0)) return true;
  if (surface.rootSymbols.has('*') && (usage.symbols.size > 0 || usage.wildcard)) return true;
  for (const symbol of usage.symbols || []) {
    if (surface.rootSymbols.has(symbol)) return true;
    // Symbol not in the barrel map at all → we can't reason about it
    if (model && !model.barrelSymbolToFile.has(symbol) && !model.barrelOpaque) {
      // unknown import (stale consumer or parse gap) — fail open
      if (surface.changedCount > 0 || surface.rootSymbols.size > 0 || surface.subpaths.size > 0) return true;
    }
  }
  for (const subpath of usage.subpaths || []) {
    if (surface.subpaths.has(subpath)) return true;
    // Subpath that doesn't resolve to a known entry (e.g. "./x.css"
    // via a glob export, or an unknown deep path)
    if (model && !model.subpathToEntry.has(subpath)) {
      if (subpath.endsWith('.css')) {
        // map "./base.css" through glob export "./*.css" → src file
        const cssName = subpath.replace(/^\.\//, '');
        for (const pattern of model.cssExportPatterns) {
          const targetTemplate = pattern.target; // "./src/styles/*.css"
          const resolvedCss = path.join(model.libDir, targetTemplate.replace(/^\.\//, '').replace('*.css', cssName.replace(/\.css$/, '') + '.css'));
          if (surface.cssFiles.has(resolvedCss)) return true;
          // also match when the glob directory itself had any dirty css
        }
        continue; // css subpath resolved cleanly and wasn't dirty
      }
      // Unknown non-css subpath → conservative
      if (surface.changedCount > 0) return true;
    }
  }
  return false;
}

// ══════════════════════════════════════════════════════════════
// CONSUMER SCANNING
// What does a service import from a given library? Scans src/**
// plus root-level config files (next.config.ts imports
// utilities-library/node in every client).
// ══════════════════════════════════════════════════════════════
const consumerScanCache = new Map(); // `${svc}|${pkgName}` -> usage
function scanConsumerUsage(serviceId, packageName) {
  const cacheKey = `${serviceId}|${packageName}`;
  if (consumerScanCache.has(cacheKey)) return consumerScanCache.get(cacheKey);
  const serviceDir = path.join(ROOT_DIR, serviceId);
  const usage = { symbols: new Set(), subpaths: new Set(), wildcard: false, importCount: 0 };

  const filesToScan = walkCodeFiles(path.join(serviceDir, 'src'));
  // Root-level build/config files participate in the shipped build
  try {
    for (const entry of fs.readdirSync(serviceDir)) {
      if (/\.config\.(ts|js|mjs|cjs)$/.test(entry) || /^next\.config\./.test(entry)) {
        filesToScan.push(path.join(serviceDir, entry));
      }
    }
  } catch { /* service dir missing — handled by caller */ }

  const escapedPkg = packageName.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');
  const quickTest = new RegExp(escapedPkg);
  for (const file of filesToScan) {
    let source;
    try { source = fs.readFileSync(file, 'utf8'); } catch { continue; }
    if (!quickTest.test(source)) continue;
    source = stripComments(source);
    for (const { clause, spec } of extractImports(source)) {
      if (spec !== packageName && !spec.startsWith(packageName + '/')) continue;
      usage.importCount++;
      if (spec === packageName) {
        const { symbols, wildcard } = parseClause(clause);
        if (wildcard) usage.wildcard = true;
        symbols.forEach(s => usage.symbols.add(s));
      } else {
        usage.subpaths.add('.' + spec.slice(packageName.length));
      }
    }
  }
  consumerScanCache.set(cacheKey, usage);
  return usage;
}

// ══════════════════════════════════════════════════════════════
// STATE: per-service saved base SHAs (.deploy-state/<svc>.deps.sha)
// ══════════════════════════════════════════════════════════════
function readSavedBases(serviceId) {
  const bases = {};
  try {
    const content = fs.readFileSync(path.join(STATE_DIR, `${serviceId}.deps.sha`), 'utf8');
    for (const line of content.split('\n')) {
      const match = line.match(/^(\S+):\s*([0-9a-f]{7,40})/);
      if (match) bases[match[1]] = match[2];
    }
  } catch { /* no marker yet — bash bootstraps it; treated as in-sync */ }
  return bases;
}

// Which libraries import which other libraries (for two-hop)?
// Derived from crossLibUsage of each lib model, mapped pkg → libId.
function libDependenciesOf(libId) {
  const model = buildLibraryModel(libId);
  if (!model) return [];
  const packageNames = new Set();
  for (const perPkg of model.crossLibUsage.values()) {
    for (const pkgName of perPkg.keys()) packageNames.add(pkgName);
  }
  const result = [];
  for (const pkgName of packageNames) {
    const otherId = pkgName.replace('@rodrigo-barraza/', '');
    if (fs.existsSync(path.join(ROOT_DIR, otherId, 'package.json'))) result.push(otherId);
  }
  return result;
}

// ══════════════════════════════════════════════════════════════
// VERDICTS
// ══════════════════════════════════════════════════════════════
const verdicts = new Map(); // svc -> { verdict, reason }
const summaryByLib = new Map(); // libId -> { affected: [], unaffected: [], failOpen: '' }
const warnings = [];

function headSha(libId) {
  const model = buildLibraryModel(libId);
  if (!model) return null;
  try { return git(model.libDir, 'rev-parse', 'HEAD').trim(); } catch { return null; }
}
const headCache = new Map();
function currentHead(libId) {
  if (!headCache.has(libId)) headCache.set(libId, headSha(libId));
  return headCache.get(libId);
}

function isLibraryDirty(libId) {
  const model = buildLibraryModel(libId);
  if (!model) return false;
  try {
    git(model.libDir, 'diff', '--quiet', 'HEAD', '--', '.');
    const untracked = git(model.libDir, 'ls-files', '--others', '--exclude-standard').trim();
    return untracked.length > 0;
  } catch { return true; }
}
const dirtyCache = new Map();
function libraryDirty(libId) {
  if (!dirtyCache.has(libId)) dirtyCache.set(libId, isLibraryDirty(libId));
  return dirtyCache.get(libId);
}

for (const [serviceId, libIds] of servicePairs) {
  const savedBases = readSavedBases(serviceId);
  const reasons = [];
  let anyAffected = false;
  let anyChanged = false;

  for (const libId of libIds) {
    const model = buildLibraryModel(libId);
    if (!model) {
      // Stale projects.json entry or word-scan phantom (e.g. the
      // merged-away service-library). A lib that isn't on disk can't
      // ship changes — ignore, but surface it once.
      if (!warnings.includes(`${libId}: directory missing — ignored (stale dependency?)`)) {
        warnings.push(`${libId}: directory missing — ignored (stale dependency?)`);
      }
      continue;
    }

    const base = OVERRIDE_BASES[libId] || savedBases[libId];
    if (!base) continue; // no marker — bash bootstraps as in-sync (existing behavior)

    const head = currentHead(libId);
    if (!head) { anyAffected = true; reasons.push(`${libId}: git unavailable`); continue; }
    if (base === head && !libraryDirty(libId) && !OVERRIDE_BASES[libId]) continue; // unchanged

    anyChanged = true;

    // Per-project override: any change to any lib → rebuild
    if (projectOverrides[serviceId] === 'all') {
      anyAffected = true;
      reasons.push(`${libId} changed (libImpact=all override)`);
      continue;
    }

    // Own surface + surfaces induced by upstream libs this lib consumes
    const surface = computeSurface(libId, base);
    const usage = scanConsumerUsage(serviceId, model.packageName);

    let hit = usageHitsSurface(usage, surface, model);
    let hitVia = hit ? 'direct' : null;

    if (!hit) {
      // Two-hop: lib M (this lib) may be dirtied by upstream lib L
      // changes even when M itself didn't change.
      for (const upstreamId of libDependenciesOf(libId)) {
        const upstreamBase = OVERRIDE_BASES[upstreamId] || savedBases[upstreamId];
        if (!upstreamBase) continue;
        const upstreamHead = currentHead(upstreamId);
        if (!upstreamHead || (upstreamBase === upstreamHead && !libraryDirty(upstreamId) && !OVERRIDE_BASES[upstreamId])) continue;
        const induced = computeInducedSurface(libId, upstreamId, upstreamBase);
        if (induced.all || usageHitsSurface(usage, { ...induced, cssFiles: new Set(), changedCount: 0 }, model)) {
          hit = true;
          hitVia = `via ${upstreamId} (${induced.all ? 'all' : induced.seeds.slice(0, 3).join(', ')})`;
          break;
        }
      }
    }

    const changeDescription = surface.all
      ? surface.reason
      : `${surface.changedCount} file${surface.changedCount === 1 ? '' : 's'} (${surface.changedSample.join(', ')}${surface.changedCount > surface.changedSample.length ? ` +${surface.changedCount - surface.changedSample.length} more` : ''})`;

    if (hit) {
      anyAffected = true;
      reasons.push(`${libId}: ${changeDescription}${hitVia && hitVia !== 'direct' ? ' ' + hitVia : ''}`);
      (summaryByLib.get(libId) || summaryByLib.set(libId, { affected: [], unaffected: [] }).get(libId)).affected.push(serviceId);
    } else {
      reasons.push(`${libId}: ${changeDescription} — not imported`);
      (summaryByLib.get(libId) || summaryByLib.set(libId, { affected: [], unaffected: [] }).get(libId)).unaffected.push(serviceId);
    }
  }

  // But: two-hop must ALSO run when the dependent lib itself didn't
  // change at all (utilities changed, components untouched). The loop
  // above only reaches induced checks for libs marked changed. Handle
  // the remaining case: for each lib the service uses that DIDN'T
  // change, check induced surfaces from its changed upstreams.
  if (!anyAffected) {
    for (const libId of libIds) {
      const model = buildLibraryModel(libId);
      if (!model) continue;
      const base = OVERRIDE_BASES[libId] || savedBases[libId];
      const head = currentHead(libId);
      const libChanged = base && head && (base !== head || libraryDirty(libId) || OVERRIDE_BASES[libId]);
      if (libChanged) continue; // already handled above
      for (const upstreamId of libDependenciesOf(libId)) {
        const upstreamBase = OVERRIDE_BASES[upstreamId] || savedBases[upstreamId];
        if (!upstreamBase) continue;
        const upstreamHead = currentHead(upstreamId);
        if (!upstreamHead || (upstreamBase === upstreamHead && !libraryDirty(upstreamId) && !OVERRIDE_BASES[upstreamId])) continue;
        anyChanged = true;
        if (projectOverrides[serviceId] === 'all') {
          anyAffected = true;
          reasons.push(`${upstreamId} changed (libImpact=all override)`);
          break;
        }
        const usage = scanConsumerUsage(serviceId, model.packageName);
        const induced = computeInducedSurface(libId, upstreamId, upstreamBase);
        if (induced.all || usageHitsSurface(usage, { ...induced, cssFiles: new Set(), changedCount: 0 }, model)) {
          anyAffected = true;
          reasons.push(`${upstreamId} → ${libId} (${induced.all ? 'all' : induced.seeds.slice(0, 3).join(', ')})`);
          break;
        }
      }
      if (anyAffected) break;
    }
  }

  const verdict = anyAffected ? 'affected' : (anyChanged ? 'unaffected' : 'none');
  verdicts.set(serviceId, { verdict, reason: reasons.join('; ') || 'no library changes' });
}

// ══════════════════════════════════════════════════════════════
// OUTPUT
// ══════════════════════════════════════════════════════════════
function shellSafe(text) {
  return text.replace(/[^a-zA-Z0-9 ,.·_:;()→—+=/@'-]/g, '').replace(/'/g, '').slice(0, 200);
}

if (HUMAN_MODE) {
  console.log('Library Impact Analysis');
  console.log('═══════════════════════');
  for (const [serviceId, { verdict, reason }] of verdicts) {
    const icon = verdict === 'affected' ? '🔨' : verdict === 'unaffected' ? '⏭️ ' : '· ';
    console.log(`${icon} ${serviceId.padEnd(28)} ${verdict.padEnd(10)} ${reason}`);
  }
  for (const warning of warnings) console.log(`⚠  ${warning}`);
} else {
  console.log('IMPACT_SCRIPT_OK=true');
  for (const [serviceId, { verdict, reason }] of verdicts) {
    console.log(`IMPACT_VERDICT[${serviceId}]='${verdict}'`);
    console.log(`IMPACT_REASON[${serviceId}]='${shellSafe(reason)}'`);
  }
  // Terminal summary → stderr (deploy-all.sh prints it)
  const counts = { affected: 0, unaffected: 0, none: 0 };
  for (const { verdict } of verdicts.values()) counts[verdict]++;
  if (counts.affected + counts.unaffected > 0) {
    console.error(`impact: ${counts.affected} affected, ${counts.unaffected} skippable, ${counts.none} untouched by library changes`);
    for (const [libId, groups] of summaryByLib) {
      if (groups.affected.length + groups.unaffected.length === 0) continue;
      console.error(`impact: ${libId} → rebuilds ${groups.affected.length}, spares ${groups.unaffected.length} consumers`);
    }
  }
  for (const warning of warnings) console.error(`impact-warn: ${warning}`);
}
