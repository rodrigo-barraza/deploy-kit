const fs = require('fs');
const path = require('path');

try {
  if (!fs.existsSync('package.json') || !fs.existsSync('package-lock.json')) {
    process.exit(0);
  }

  const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
  const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
  const allDeps = { ...pkg.dependencies, ...pkg.devDependencies };
  const customDeps = Object.keys(allDeps).filter(dep => dep.startsWith('@rodrigo-barraza/'));
  
  const staleLibraries = [];
  for (const dependencyName of customDeps) {
    const libraryName = dependencyName.replace('@rodrigo-barraza/', '');
    const libraryDir = path.resolve('..', libraryName);
    if (!fs.existsSync(libraryDir)) {
      continue;
    }
    
    let lockedSha = '';
    const lockKey = `node_modules/${dependencyName}`;
    if (lock.packages && lock.packages[lockKey] && lock.packages[lockKey].resolved) {
      const resolved = lock.packages[lockKey].resolved;
      const hashIndex = resolved.indexOf('#');
      if (hashIndex !== -1) {
        lockedSha = resolved.substring(hashIndex + 1);
      }
    } else if (lock.dependencies && lock.dependencies[dependencyName] && lock.dependencies[dependencyName].version) {
      const version = lock.dependencies[dependencyName].version;
      const hashIndex = version.indexOf('#');
      if (hashIndex !== -1) {
        lockedSha = version.substring(hashIndex + 1);
      }
    }
    
    if (!lockedSha) {
      continue;
    }
    
    try {
      const execSync = require('child_process').execSync;
      const currentSha = execSync('git rev-parse HEAD', { cwd: libraryDir }).toString().trim();
      if (currentSha && !lockedSha.startsWith(currentSha) && !currentSha.startsWith(lockedSha)) {
        staleLibraries.push(libraryName);
      }
    } catch (err) {}
  }
  if (staleLibraries.length > 0) {
    console.log(staleLibraries.join(' '));
  }
} catch (e) {
  process.exit(0);
}
