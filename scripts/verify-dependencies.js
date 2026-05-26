const fs = require('fs');
const path = require('path');

const ROOT_DIR = path.resolve(__dirname, '../..');
const PROJECTS_JSON = path.join(ROOT_DIR, 'vault-service', 'projects.json');

// Color helpers
const CLR = {
  reset: '\x1b[0m',
  bold: '\x1b[1m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  cyan: '\x1b[36m',
  gray: '\x1b[90m'
};

if (!fs.existsSync(PROJECTS_JSON)) {
  console.error(`${CLR.red}ERROR: projects.json not found at ${PROJECTS_JSON}${CLR.reset}`);
  process.exit(1);
}

const configData = JSON.parse(fs.readFileSync(PROJECTS_JSON, 'utf8'));
const projects = configData.projects || [];
const allProjectIds = new Set(projects.map(p => p.id));
const projectMap = new Map(projects.map(p => [p.id, p]));

// Parse command line arguments
const isFixMode = process.argv.includes('--fix');

console.log(`${CLR.cyan}${CLR.bold}═══════════════════════════════════════════════════════════${CLR.reset}`);
console.log(`  ${CLR.cyan}${CLR.bold}🔍 STATIC WORKSPACE DEPENDENCY ANALYZER${CLR.reset}`);
console.log(`  Mode: ${isFixMode ? CLR.green + 'Auto-Fix (--fix)' : CLR.yellow + 'Audit Only'}${CLR.reset}`);
console.log(`${CLR.cyan}${CLR.bold}═══════════════════════════════════════════════════════════${CLR.reset}\n`);

let totalDiscrepancies = 0;
let hasModifiedProjects = false;

projects.forEach(proj => {
  const projDir = path.join(ROOT_DIR, proj.id);
  const pkgPath = path.join(projDir, 'package.json');
  
  if (!fs.existsSync(pkgPath)) {
    return; // Skip services without a package.json (e.g. purely external Docker containers)
  }

  try {
    const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
    const dependencies = { ...pkg.dependencies, ...pkg.devDependencies };

    // 1. Library Dependencies (Derived from package.json)
    const detectedDeps = new Set();
    Object.keys(dependencies).forEach(dep => {
      if (dep.startsWith('@rodrigo-barraza/')) {
        const libId = dep.replace('@rodrigo-barraza/', '');
        if (allProjectIds.has(libId)) {
          detectedDeps.add(libId);
        }
      } else if (allProjectIds.has(dep)) {
        detectedDeps.add(dep);
      }
    });

    // 2. Service-to-Service & Infrastructure Dependencies (Derived from static analysis of code)
    // We scan src/ files for references to known service hosts, database connections, or config variables
    const scanDir = path.join(projDir, 'src');
    if (fs.existsSync(scanDir)) {
      const filesToScan = [];
      const collectFiles = (dir) => {
        fs.readdirSync(dir).forEach(file => {
          const fullPath = path.join(dir, file);
          const stat = fs.statSync(fullPath);
          if (stat.isDirectory()) {
            collectFiles(fullPath);
          } else if (stat.isFile() && /\.(tsx?|jsx?|json)$/.test(file) && !file.includes('.test.')) {
            filesToScan.push(fullPath);
          }
        });
      };
      
      collectFiles(scanDir);

      filesToScan.forEach(file => {
        const content = fs.readFileSync(file, 'utf8');
        
        // Scan for MongoDB references
        if (/mongoose|mongodb:\/\//.test(content)) {
          detectedDeps.add('mongodb');
        }
        
        // Scan for MinIO/S3 references
        if (/minioBucket|s3Client|@aws-sdk\/client-s3/.test(content)) {
          detectedDeps.add('minio');
        }

        // Scan for Prism Service URL references
        if (/PRISM_SERVICE|prism-service|api\.prism\.rod\.dev/.test(content)) {
          detectedDeps.add('prism-service');
        }

        // Scan for Messages Service URL references
        if (/MESSAGES_SERVICE|messages-service|api\.messages\.rod\.dev/.test(content)) {
          detectedDeps.add('messages-service');
        }
        
        // Scan for Sessions Service references
        if (/SESSIONS_SERVICE|sessions-service|api\.sessions\.rod\.dev/.test(content)) {
          detectedDeps.add('sessions-service');
        }
      });
    }

    // 3. Vault Service (Universal config resolver, assumed required if not vault-service itself)
    if (proj.id !== 'vault-service' && proj.projectType !== 'Library') {
      detectedDeps.add('vault-service');
    }

    // Read currently declared dependencies
    const declaredDepsMap = new Map((proj.dependsOn || []).map(d => [d.id, d]));
    const declaredDepsSet = new Set(declaredDepsMap.keys());

    const missingInDeclared = [...detectedDeps].filter(id => !declaredDepsSet.has(id));
    const extraInDeclared = [...declaredDepsSet].filter(id => {
      // Retain manual system config dependencies (e.g. deploy-kit or lm-studio which might not have code references)
      if (id === 'deploy-kit' || id.startsWith('lm-studio')) {
        return false;
      }
      return !detectedDeps.has(id);
    });

    if (missingInDeclared.length > 0 || extraInDeclared.length > 0) {
      console.log(`📌 ${CLR.bold}${proj.id}${CLR.reset} (${CLR.gray}${proj.projectType || 'Service'}${CLR.reset})`);
      totalDiscrepancies += missingInDeclared.length + extraInDeclared.length;

      if (missingInDeclared.length > 0) {
        console.log(`  ${CLR.red}Missing dependencies:${CLR.reset} ${missingInDeclared.join(', ')}`);
        if (isFixMode) {
          proj.dependsOn = proj.dependsOn || [];
          missingInDeclared.forEach(depId => {
            const isLib = projectMap.get(depId)?.projectType === 'Library';
            proj.dependsOn.push({
              id: depId,
              criticality: (depId === 'deploy-kit' || !isLib) ? 'optional' : 'required'
            });
          });
          console.log(`    ${CLR.green}✔ Auto-added missing dependencies${CLR.reset}`);
          hasModifiedProjects = true;
        }
      }

      if (extraInDeclared.length > 0) {
        console.log(`  ${CLR.yellow}Stale dependencies:${CLR.reset} ${extraInDeclared.join(', ')}`);
        if (isFixMode) {
          proj.dependsOn = proj.dependsOn.filter(d => !extraInDeclared.includes(d.id));
          console.log(`    ${CLR.green}✔ Auto-removed stale dependencies${CLR.reset}`);
          hasModifiedProjects = true;
        }
      }
      console.log();
    }
  } catch (err) {
    console.error(`${CLR.red}Failed scanning ${proj.id}: ${err.message}${CLR.reset}`);
  }
});

if (isFixMode && hasModifiedProjects) {
  try {
    fs.writeFileSync(PROJECTS_JSON, JSON.stringify(configData, null, 2) + '\n', 'utf8');
    console.log(`${CLR.green}${CLR.bold}✔ SUCCESS: Alignments written to projects.json!${CLR.reset}\n`);
  } catch (err) {
    console.error(`${CLR.red}Failed writing changes to projects.json: ${err.message}${CLR.reset}`);
  }
}

console.log(`${CLR.cyan}${CLR.bold}═══════════════════════════════════════════════════════════${CLR.reset}`);
if (totalDiscrepancies === 0) {
  console.log(`  ${CLR.green}${CLR.bold}✔ All dependency configurations are 100% accurate!${CLR.reset}`);
} else {
  console.log(`  ${CLR.yellow}${CLR.bold}⚠ Found ${totalDiscrepancies} discrepancies!${CLR.reset}`);
  if (!isFixMode) {
    console.log(`  ${CLR.gray}Run \`npm run verify:deps -- --fix\` to automatically align them.${CLR.reset}`);
  }
}
console.log(`${CLR.cyan}${CLR.bold}═══════════════════════════════════════════════════════════${CLR.reset}\n`);
