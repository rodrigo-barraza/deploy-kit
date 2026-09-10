const fs = require('fs');
const path = require('path');

const projectsJsonPath = process.argv[2];
const rootDir = process.argv[3];

if (!projectsJsonPath || !rootDir) {
  console.error("Usage: node parse-projects.js <projects-json-path> <root-dir>");
  process.exit(1);
}

const output = [];
const quote = value => "'" + String(value).replace(/'/g, "'\"'\"'") + "'";
const emit = (array, id, value) => output.push(`${array}[${quote(id)}]=${quote(value)}`);
const validId = id => typeof id === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9_-]*$/.test(id);
try {
  const configData = JSON.parse(fs.readFileSync(projectsJsonPath, 'utf8'));
  if (!Array.isArray(configData.projects) || !Array.isArray(configData.devices)) throw new Error('projects and devices must be arrays');
  for (const entries of [configData.projects, configData.devices, configData.infrastructure || []]) {
    const ids = new Set();
    for (const entry of entries) {
      if (!validId(entry.id) || ids.has(entry.id)) throw new Error(`Invalid or duplicate ID: ${entry.id}`);
      ids.add(entry.id);
    }
  }
  for (const project of configData.projects) {
    if (project.deployTier !== undefined && (!Number.isInteger(project.deployTier) || project.deployTier < 0 || project.deployTier > 64)) throw new Error(`Invalid deployTier: ${project.id}`);
  }
  const host = configData.defaultHost || 'localhost';

  // Build device lookup
  const devices = {};
  for (const device of (configData.devices || [])) {
    if (device.deploy?.method && !['ssh', 'docker-api'].includes(device.deploy.method)) throw new Error(`Invalid deploy method: ${device.id}`);
    if (device.arch && !['amd64', 'arm64'].includes(device.arch)) throw new Error(`Unsupported architecture: ${device.id}`);
    for (const value of [device.dockerBin, device.deploy?.dockerBin, device.deploy?.composeRoot]) {
      if (value && /['\r\n]/.test(value)) throw new Error(`Unsupported quote/newline in remote path: ${device.id}`);
    }
    devices[device.id] = device;
  }
  const defaultTarget = 'synology';

  // Emit device deploy metadata
  const dockerDeviceIds = [];
  for (const device of (configData.devices || [])) {
    const deployment = device.deploy || {};
    const method = deployment.method || 'ssh';
    emit('DEVICE_METHOD', device.id, method);
    emit('DEVICE_HOSTNAME', device.id, device.hostname || '');
    emit('DEVICE_ARCH', device.id, device.arch || '');
    emit('DEVICE_SSH_ALIAS', device.id, device.sshAlias || '');
    emit('DEVICE_DOCKER_BIN', device.id, device.dockerBin || deployment.dockerBin || 'docker');
    emit('DEVICE_DOCKER_API', device.id, device.dockerApi || deployment.dockerApi || '');
    emit('DEVICE_COMPOSE_ROOT', device.id, deployment.composeRoot || '');
    emit('DEVICE_SMB_ROOT', device.id, deployment.smbRoot || '');
    if (deployment.method) {
      dockerDeviceIds.push(device.id);
    }
  }
  output.push(`DOCKER_DEVICES=(${dockerDeviceIds.join(' ')})`);

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
    if (!targetDevice || !targetDevice.deploy?.method) throw new Error(`Unknown or non-deployable target ${targetId} for ${project.id}`);
    const serviceHost = targetDevice ? targetDevice.hostname : host;

    emit('SVC_DEPLOY_TARGET', project.id, targetId);
    if (project.port && project.healthPath) {
      emit('SVC_HEALTH_URL', project.id, `http://${serviceHost}:${project.port}${project.healthPath}`);
    }
  }
  const maxTier = Math.max(0, ...Object.keys(tiers).map(Number));
  output.push(`MAX_TIER=${maxTier}`);
  for (let tierIndex = 0; tierIndex <= maxTier; tierIndex++) {
    const ids = (tiers[tierIndex] || []).join(' ');
    emit('TIER_SERVICES', tierIndex, ids);
    output.push(`TIER_${tierIndex}=(${ids})`);
  }

  // ── DYNAMIC RUNTIME DEPENDENCY SCANNING ──
  const allProjectIds = configData.projects.map(project => project.id);
  const infrastructureIds = (configData.infrastructure || []).map(infra => infra.id);
  const candidateIds = [...allProjectIds, ...infrastructureIds, 'mongodb', 'minio'];
  const libraries = configData.projects.filter(project => project.projectType === 'Library');
  const libraryIds = new Set(libraries.map(library => library.id));

  const libraryDependencies = {};
  const projectLibraries = new Map();
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
            const stats = fs.lstatSync(fullPath);
            if (stats.isSymbolicLink() || ['node_modules', '.git', 'dist'].includes(fileName)) return;
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
          
          const code = content.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/^\s*\/\/.*$/gm, '');
          const words = new Set(code.split(/[^a-zA-Z0-9_-]/));
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

    projectLibraries.set(project.id, [...detectedLibraryDependencies]);
    if (detectedLibraryDependencies.size > 0) {
      emit('SVC_LIB_DEPS', project.id, [...detectedLibraryDependencies].join(' '));
    }
    if (detectedDependencies.size > 0) {
      emit('SVC_DEPS', project.id, [...detectedDependencies].join(' '));
    }
  }

  const sortedIds = [];
  const visitedIds = new Set();
  const visitingIds = new Set();
  function visit(id) {
    if (visitedIds.has(id)) {
      return;
    }
    if (visitingIds.has(id)) throw new Error(`Library dependency cycle: ${id}`);
    visitingIds.add(id);
    const dependencies = libraryDependencies[id] || [];
    for (const dep of dependencies) {
      visit(dep);
    }
    visitingIds.delete(id);
    visitedIds.add(id);
    sortedIds.push(id);
  }
  libraries.forEach(lib => visit(lib.id));
  output.push(`LIBRARY_IDS=(${sortedIds.join(' ')})`);
  // Track transitive libraries too: a components consumer can be affected by
  // utilities even when it never names utilities in its own package.json.
  for (const [id, direct] of projectLibraries) {
    const closure = new Set();
    function add(lib) {
      if (closure.has(lib)) return;
      closure.add(lib);
      for (const dep of libraryDependencies[lib] || []) add(dep);
    }
    direct.forEach(add);
    emit('SVC_LIB_DEPS', id, [...closure].sort().join(' '));
  }
  process.stdout.write(output.join('\n') + '\n');

} catch (err) {
  console.error("Error executing parse-projects.js:", err.message);
  process.exit(1);
}
