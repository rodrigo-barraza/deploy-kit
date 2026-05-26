const fs = require('fs');
const path = require('path');

const projectsJsonPath = process.argv[2];
const rootDir = process.argv[3];

if (!projectsJsonPath || !rootDir) {
  console.error("Usage: node parse-projects.js <projects-json-path> <root-dir>");
  process.exit(1);
}

try {
  const configData = JSON.parse(fs.readFileSync(projectsJsonPath, 'utf8'));
  const host = configData.defaultHost || 'localhost';

  // Build device lookup
  const devices = {};
  for (const device of (configData.devices || [])) {
    devices[device.id] = device;
  }
  const defaultTarget = 'synology';

  // Emit device deploy metadata
  const dockerDeviceIds = [];
  for (const device of (configData.devices || [])) {
    const deployment = device.deploy || {};
    const method = deployment.method || 'ssh';
    console.log(`DEVICE_METHOD[${device.id}]="${method}"`);
    console.log(`DEVICE_HOSTNAME[${device.id}]="${device.hostname || ''}"`);
    console.log(`DEVICE_SSH_ALIAS[${device.id}]="${device.sshAlias || ''}"`);
    console.log(`DEVICE_DOCKER_BIN[${device.id}]="${deployment.dockerBin || 'docker'}"`);
    console.log(`DEVICE_DOCKER_API[${device.id}]="${deployment.dockerApi || ''}"`);
    console.log(`DEVICE_COMPOSE_ROOT[${device.id}]="${deployment.composeRoot || ''}"`);
    console.log(`DEVICE_SMB_ROOT[${device.id}]="${deployment.smbRoot || ''}"`);
    if (deployment.method) {
      dockerDeviceIds.push(device.id);
    }
  }
  console.log(`DOCKER_DEVICES=(${dockerDeviceIds.join(' ')})`);

  // Emit tier + service metadata
  const tiers = {};
  for (const project of configData.projects) {
    let tier = project.deployTier;
    if (typeof tier !== 'number') {
      if (project.id.endsWith('-service') || project.id.endsWith('-client')) {
        tier = 1;
      } else if (project.id.endsWith('-bot')) {
        tier = 2;
      } else {
        continue;
      }
    }
    (tiers[tier] ??= []).push(project.id);

    const targetId = project.deployTarget || defaultTarget;
    const targetDevice = devices[targetId];
    const serviceHost = targetDevice ? targetDevice.hostname : host;

    console.log(`SVC_DEPLOY_TARGET[${project.id}]="${targetId}"`);
    if (project.port && project.healthPath) {
      console.log(`SVC_HEALTH_URL[${project.id}]="http://${serviceHost}:${project.port}${project.healthPath}"`);
    }
  }
  const maxTier = Math.max(...Object.keys(tiers).map(Number));
  console.log(`MAX_TIER=${maxTier}`);
  for (let tierIndex = 0; tierIndex <= maxTier; tierIndex++) {
    const ids = (tiers[tierIndex] || []).join(' ');
    console.log(`TIER_SERVICES[${tierIndex}]="${ids}"`);
    console.log(`TIER_${tierIndex}=(${ids})`);
  }

  // ── DYNAMIC RUNTIME DEPENDENCY SCANNING ──
  const allProjectIds = configData.projects.map(project => project.id);
  const infrastructureIds = (configData.infrastructure || []).map(infra => infra.id);
  const candidateIds = [...allProjectIds, ...infrastructureIds, 'mongodb', 'minio'];
  const libraries = configData.projects.filter(project => project.projectType === 'Library');
  const libraryIds = new Set(libraries.map(library => library.id));

  const libraryDependencies = {};
  libraries.forEach(library => {
    libraryDependencies[library.id] = [];
  });

  for (const project of configData.projects) {
    const projectDir = path.join(rootDir, project.id);
    const packageJsonPath = path.join(projectDir, 'package.json');
    const detectedDependencies = new Set();
    const detectedLibraryDependencies = new Set();

    if (fs.existsSync(packageJsonPath)) {
      try {
        const pkg = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
        const dependencies = { ...pkg.dependencies, ...pkg.devDependencies };
        Object.keys(dependencies).forEach(dependencyName => {
          if (dependencyName.startsWith('@rodrigo-barraza/')) {
            const libraryId = dependencyName.replace('@rodrigo-barraza/', '');
            if (libraryIds.has(libraryId)) {
              detectedLibraryDependencies.add(libraryId);
              detectedDependencies.add(libraryId);
              if (project.projectType === 'Library') {
                libraryDependencies[project.id].push(libraryId);
              }
            }
          } else if (candidateIds.includes(dependencyName)) {
            detectedDependencies.add(dependencyName);
          }
        });
      } catch (err) {}
    }

    const scanDir = path.join(projectDir, 'src');
    if (fs.existsSync(scanDir)) {
      const filesToScan = [];
      const collectFiles = (directoryPath) => {
        try {
          fs.readdirSync(directoryPath).forEach(fileName => {
            const fullPath = path.join(directoryPath, fileName);
            const stats = fs.statSync(fullPath);
            if (stats.isDirectory()) {
              collectFiles(fullPath);
            } else if (stats.isFile() && /\.(tsx?|jsx?|json|js)$/.test(fileName) && !fileName.includes('.test.')) {
              filesToScan.push(fullPath);
            }
          });
        } catch (err) {}
      };
      collectFiles(scanDir);

      filesToScan.forEach(filePath => {
        try {
          const content = fs.readFileSync(filePath, 'utf8');
          if (/mongoose|mongodb:\/\//.test(content)) {
            detectedDependencies.add('mongodb');
          }
          if (/minioBucket|s3Client|@aws-sdk\/client-s3/.test(content)) {
            detectedDependencies.add('minio');
          }
          
          const words = new Set(content.split(/[^a-zA-Z0-9_-]/));
          candidateIds.forEach(candidateId => {
            if (candidateId === project.id) {
              return;
            }
            if (words.has(candidateId)) {
              detectedDependencies.add(candidateId);
              if (libraryIds.has(candidateId)) {
                detectedLibraryDependencies.add(candidateId);
                if (project.projectType === 'Library') {
                  libraryDependencies[project.id].push(candidateId);
                }
              }
            }
          });
        } catch (err) {}
      });
    }

    if (project.id !== 'vault-service' && project.projectType !== 'Library' && project.projectType !== 'Tool' && project.projectType !== 'Kit') {
      detectedDependencies.add('vault-service');
    }

    if (detectedLibraryDependencies.size > 0) {
      console.log(`SVC_LIB_DEPS[${project.id}]="${[...detectedLibraryDependencies].join(' ')}"`);
    }
    if (detectedDependencies.size > 0) {
      console.log(`SVC_DEPS[${project.id}]="${[...detectedDependencies].join(' ')}"`);
    }
  }

  const sortedIds = [];
  const visitedIds = new Set();
  function visit(id) {
    if (visitedIds.has(id)) {
      return;
    }
    visitedIds.add(id);
    const dependencies = libraryDependencies[id] || [];
    for (const dep of dependencies) {
      visit(dep);
    }
    sortedIds.push(id);
  }
  libraries.forEach(lib => visit(lib.id));
  console.log(`LIBRARY_IDS=(${sortedIds.join(' ')})`);

} catch (err) {
  console.error("Error executing parse-projects.js:", err.message);
  process.exit(1);
}
