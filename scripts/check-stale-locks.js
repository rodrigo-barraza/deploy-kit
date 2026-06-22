const fs = require('fs');
const path = require('path');

try {
  if (!fs.existsSync('package.json') || !fs.existsSync('pnpm-lock.yaml')) {
    process.exit(0);
  }

  const packageJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));
  const lockfileContent = fs.readFileSync('pnpm-lock.yaml', 'utf8');
  const allDependencies = { ...packageJson.dependencies, ...packageJson.devDependencies };
  const customDependencies = Object.keys(allDependencies).filter(dependency => dependency.startsWith('@rodrigo-barraza/'));
  
  const staleLibraries = [];
  for (const dependencyName of customDependencies) {
    const libraryName = dependencyName.replace('@rodrigo-barraza/', '');
    const libraryDirectory = path.resolve('..', libraryName);
    if (!fs.existsSync(libraryDirectory)) {
      continue;
    }
    
    // Find the locked commit SHA within the dependency's block in pnpm-lock.yaml
    let lockedSha = '';
    const lines = lockfileContent.split('\n');
    const escapedDependency = dependencyName.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');
    const dependencyRegex = new RegExp(`^\\s*['"]?${escapedDependency}['"]?:`);
    
    for (let index = 0; index < lines.length; index++) {
      const line = lines[index];
      if (dependencyRegex.test(line)) {
        const baseIndentation = line.search(/\S/);
        for (let nextIndex = index + 1; nextIndex < lines.length; nextIndex++) {
          const nextLine = lines[nextIndex];
          if (nextLine.trim() === '') {
            continue;
          }
          const nextIndentation = nextLine.search(/\S/);
          if (nextIndentation <= baseIndentation) {
            break;
          }
          const commitShaMatch = nextLine.match(/(?:commit|tar\.gz\/|#)([0-9a-f]{40})/i);
          if (commitShaMatch) {
            lockedSha = commitShaMatch[1];
            break;
          }
        }
        if (lockedSha) {
          break;
        }
      }
    }

    if (!lockedSha) {
      continue;
    }
    
    try {
      const execSync = require('child_process').execSync;
      const currentSha = execSync('git rev-parse HEAD', { cwd: libraryDirectory }).toString().trim();
      if (currentSha && !lockedSha.startsWith(currentSha) && !currentSha.startsWith(lockedSha)) {
        staleLibraries.push(libraryName);
      }
    } catch (error) {}
  }
  if (staleLibraries.length > 0) {
    console.log(staleLibraries.join(' '));
  }
} catch (error) {
  process.exit(0);
}
