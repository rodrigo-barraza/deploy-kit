"""Run real scripts with local Git repos and mocked external deployment commands."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

KIT = Path(__file__).resolve().parents[1]
NODE = shutil.which('node')

def real_git(directory, *args):
    return subprocess.check_output(['/usr/bin/git', '-C', str(directory), *args], stderr=subprocess.DEVNULL, text=True).strip()

class DeploymentTests(unittest.TestCase):
    def setUp(self):
        if not NODE: self.skipTest('Node.js is required')
        self.temp = tempfile.TemporaryDirectory(prefix='deploy kit tests ')
        self.root = Path(self.temp.name)
        self.kit = self.root / 'deploy-kit'
        shutil.copytree(KIT, self.kit, ignore=shutil.ignore_patterns('.git', '.claude', '.deploy-logs', '.deploy-state', 'node_modules', '__pycache__'))
        (self.kit / '.env.deploy').write_text('EXAMPLE=deployment\n')
        self.bin = self.root / 'bin'; self.bin.mkdir()
        for name in ['node', 'git', 'docker', 'ssh', 'ssh-add', 'ssh-agent', 'curl', 'pnpm', 'powershell.exe']:
            shutil.copy2(KIT / 'tests/mock-command.py', self.bin / name)
            (self.bin / name).chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + ':/usr/bin:/bin', REAL_NODE=NODE,
                        TEST_ROOT=str(self.root), SSH_AUTH_SOCK='/tmp/unused-mock-agent',
                        BUILD_PHASE_TIMEOUT='8', TRANSFER_PHASE_TIMEOUT='2', RESTART_PHASE_TIMEOUT='5',
                        HEALTH_GATE_TIMEOUT='1', HEALTH_GATE_INTERVAL='1',
                        CONTAINER_HEALTH_ATTEMPTS='1', CONTAINER_HEALTH_INTERVAL='1')
        for key in ['DEPLOY_ROOT_DIR', 'DEPLOY_CONFIG_DIR', 'DEPLOY_STATE_ROOT', 'DEPLOY_ORCHESTRATED', 'PROJECTS_JSON_PATH', 'SKIP_TESTS', 'BASH_ENV', 'DOCKER_DESKTOP_EXE', 'DOCKER_DESKTOP_CLI']:
            self.env.pop(key, None)
        self.registry = {'projects': [], 'devices': [
            {'id': 'target', 'hostname': 'mock-target', 'dockerApi': 'mock-target', 'deploy': {'method': 'docker-api'}},
            {'id': 'source', 'hostname': 'mock-source', 'dockerApi': 'mock-source', 'deploy': {'method': 'docker-api'}},
        ]}
        self.add_service('vault-service', 0)
        self.add_service('fixture-service', 1)
        self.save_registry()
        real_git(self.root / 'vault-service', 'add', 'projects.json')
        self.commit('vault-service', 'registry')
        (self.kit / 'edge/sync-config.sh').write_text('''#!/bin/bash
python3 - <<'PY'
import json, os
with open(os.path.join(os.environ['TEST_ROOT'], 'events.jsonl'), 'a') as f:
    f.write(json.dumps({'event':'edge-sync'})+'\\n')
PY
''')

    def tearDown(self): self.temp.cleanup()

    def add_service(self, name, tier=1, hooks=''):
        directory = self.root / name; directory.mkdir()
        (directory / '.gitignore').write_text('node_modules/\n.env\n.deploy-logs/\n')
        (directory / 'deploy.sh').write_text('''#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="''' + name + '''"
''' + hooks + '''
source "${SCRIPT_DIR}/../deploy-kit/lib.sh"
''')
        (directory / 'Dockerfile').write_text('FROM scratch\n')
        (directory / 'docker-compose.yml').write_text('services:\n  app:\n    image: ' + name + ':latest\n    env_file: .env\n')
        (directory / 'package.json').write_text(json.dumps({'name': name}))
        (directory / '.env').write_text('EXAMPLE=development\n')
        real_git(directory, 'init', '-q', '-b', 'main')
        real_git(directory, 'config', 'user.name', 'Deployment Test')
        real_git(directory, 'config', 'user.email', 'test@example.invalid')
        real_git(directory, 'add', '.')
        self.commit(name, 'initial')
        self.registry['projects'].append({'id': name, 'deployTier': tier, 'deployTarget': 'target', 'port': 8000 + len(self.registry['projects']), 'healthPath': '/health/' + name})

    def commit(self, service, message='test change'):
        directory = self.root / service
        real_git(directory, 'add', '.')
        real_git(directory, 'commit', '-qm', message)

    def save_registry(self):
        (self.root / 'vault-service/projects.json').write_text(json.dumps(self.registry))

    def events(self, name=None, service=None):
        file = self.root / 'events.jsonl'
        rows = [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []
        return [row for row in rows if (name is None or row['event'] == name) and (service is None or row.get('service') == service)]

    def clear_events(self): (self.root / 'events.jsonl').write_text('')

    def run_deploy(self, *args, env=None, skip_pull=True, skip_tests=True, kit=None, timeout=18):
        command = ['bash', str((kit or self.kit) / 'deploy-all.sh'), '--ignore-temp-skip']
        if skip_pull: command.append('--skip-pull')
        if skip_tests: command.append('--skip-tests')
        command.extend(args)
        return self.run_command(command, env, timeout)

    def run_command(self, command, env=None, timeout=18):
        process = subprocess.Popen(command, cwd=self.kit, env=dict(self.env, **(env or {})),
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try: output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
            self.fail('Deployment hung:\n' + output[-12000:])
        self.output = output
        return process.returncode, output

    def assert_ok(self, result): self.assertEqual(result[0], 0, result[1][-12000:])
    def assert_failed(self, result): self.assertNotEqual(result[0], 0, result[1][-12000:])

    def manifest(self, mode, service='fixture-service', target='target'):
        return self.kit / '.deploy-state' / mode / target / (service + '.json')

    def seed_source(self, service='fixture-service'):
        (self.root / 'docker-state.json').write_text(json.dumps({'images': {}, 'containers': {'mock-source': {service: {'running': True}}}, 'builds': 0, 'active': 0, 'maximum': 0}))

    def test_dry_run_has_no_mutations_or_hooks(self):
        file = self.root / 'fixture-service/deploy.sh'
        file.write_text(file.read_text().replace('source ', 'EXTRA_VALIDATE() { touch validation-ran; }\nPRE_TEST() { touch test-hook-ran; }\nPRE_BUILD() { touch build-hook-ran; }\nsource ', 1))
        (self.root / 'fixture-service/package.json').write_text('{"scripts":{"test":"vitest"}}')
        (self.root / 'fixture-service/boot.js').write_text('original boot')
        before = real_git(self.root / 'fixture-service', 'status', '--porcelain')
        self.assert_ok(self.run_deploy('--dry-run', skip_tests=False))
        self.assertFalse(self.events())
        self.assertFalse((self.kit / '.deploy-state').exists())
        self.assertEqual(before, real_git(self.root / 'fixture-service', 'status', '--porcelain'))
        for name in ['validation-ran', 'test-hook-ran', 'build-hook-ran']:
            self.assertFalse((self.root / 'fixture-service' / name).exists())
        self.assertEqual((self.root / 'fixture-service/boot.js').read_text(), 'original boot')

    def test_build_only_then_changed_deploy_reuses_build_and_deploys(self):
        self.assert_ok(self.run_deploy('--build-only'))
        self.assertTrue(self.manifest('built').exists())
        self.assertFalse(self.manifest('deployed').exists())
        remote = [e for e in self.events('docker') if e['host'] != 'local']
        self.assertEqual(remote, [])
        self.clear_events()
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertFalse(self.events('build-start'))
        self.assertTrue(self.events('restart', 'fixture-service'))
        self.assertTrue(self.manifest('deployed').exists())
        self.clear_events()
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertFalse(self.events('build-start'))
        self.assertFalse(self.events('restart'))

    def test_failed_transfer_retries_deployment_without_rebuild(self):
        self.assert_failed(self.run_deploy(env={'FAIL_TRANSFER': 'fixture-service'}))
        self.assertTrue(self.manifest('built').exists())
        self.assertFalse(self.manifest('deployed').exists())
        self.clear_events()
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertFalse(self.events('build-start', 'fixture-service'))
        self.assertTrue(self.events('restart', 'fixture-service'))

    def test_failed_foundation_blocks_dependents_in_both_modes(self):
        for mode in [(), ('--no-parallel',)]:
            with self.subTest(mode=mode):
                self.clear_events()
                self.assert_failed(self.run_deploy(*mode, env={'FAIL_BUILD': 'vault-service'}))
                self.assertFalse(self.events('restart', 'fixture-service'))

    def test_unhealthy_foundation_blocks_and_does_not_advance_state(self):
        self.assert_failed(self.run_deploy(env={'FAIL_HEALTH': 'vault-service'}))
        self.assertFalse(self.events('restart', 'fixture-service'))
        self.assertFalse(self.manifest('deployed', 'vault-service').exists())

    def test_container_gate_outlasts_the_first_health_probe(self):
        # An app still booting fails its own health test, so the gate waits on Docker.
        probing = {'STARTING_PROBES': 'vault-service:3', 'CONTAINER_HEALTH_ATTEMPTS': '5', 'PROBE_FAILS': 'vault-service'}
        self.assert_ok(self.run_deploy(env=probing))
        self.assertTrue(self.manifest('deployed', 'vault-service').exists())
        self.assertIn('health check starting', self.output)
        self.assert_failed(self.run_deploy(env=dict(probing, CONTAINER_HEALTH_ATTEMPTS='2')))
        self.assertIn('did not become running/healthy (status: true|starting)', self.output)

    def test_a_passing_health_test_does_not_wait_for_dockers_first_probe(self):
        # Docker would answer `starting` three more times; one inspect is all the budget there is.
        self.assert_ok(self.run_deploy(env={'STARTING_PROBES': 'vault-service:3', 'CONTAINER_HEALTH_ATTEMPTS': '1'}))
        probes = self.events('probe', 'vault-service')
        self.assertEqual(len(probes), 1); self.assertEqual(probes[0]['args'], ['wget', '-qO-', 'http://localhost/health'])
        self.assertIn('Container running: vault-service (its health test passes)', self.output)
        self.assertTrue(self.manifest('deployed', 'vault-service').exists())

    def test_the_health_test_crosses_the_ssh_boundary_intact(self):
        self.registry['devices'][0]['deploy'] = {'method': 'ssh', 'composeRoot': '/mock remote'}
        self.registry['devices'][0]['sshAlias'] = 'fake-nas'
        self.save_registry()
        self.assert_ok(self.run_deploy('--only=fixture-service', env={'STARTING_PROBES': 'fixture-service:3', 'CONTAINER_HEALTH_ATTEMPTS': '1'}))
        self.assertEqual([e['args'] for e in self.events('probe', 'fixture-service')], [['wget', '-qO-', 'http://localhost/health']])
        self.assertTrue(self.manifest('deployed').exists())

    def test_a_deployed_stack_comes_back_with_the_docker_engine_but_its_one_shot_jobs_do_not(self):
        # Container Manager stops every container explicitly; `unless-stopped`
        # then leaves them down for good. The deploy leaves `always` instead,
        # on every container the compose file gave `unless-stopped` only.
        job = {'STACK_JOB': 'fixture-service:fixture-service-migrate'}
        self.assert_ok(self.run_deploy('--only=fixture-service', env=job))
        updates = self.events('update')
        self.assertEqual([(e['host'], e['names']) for e in updates], [('mock-target', ['fixture-service'])])
        self.assertIn('--restart=always', updates[0]['args'])
        state = json.loads((self.root / 'docker-state.json').read_text())['containers']['mock-target']
        self.assertEqual(state['fixture-service']['restart'], 'always')
        self.assertEqual(state['fixture-service-migrate']['restart'], 'no')

        # The SSH road (the NAS) does the same across the SSH boundary.
        self.clear_events()
        self.registry['devices'][0]['deploy'] = {'method': 'ssh', 'composeRoot': '/mock remote'}
        self.registry['devices'][0]['sshAlias'] = 'fake-nas'
        self.save_registry()
        (self.root / 'fixture-service/change.txt').write_text('redeploy\n'); self.commit('fixture-service')
        self.assert_ok(self.run_deploy('--only=fixture-service', env=job))
        self.assertEqual([e['names'] for e in self.events('update')], [['fixture-service']])

    def test_docker_down_fails_before_any_work_unless_docker_desktop_starts(self):
        missing = {'FAIL_DOCKER_INFO': '99', 'DOCKER_DESKTOP_EXE': str(self.root / 'absent.exe')}
        self.assert_failed(self.run_deploy(skip_pull=False, env=missing))
        self.assertIn('Docker is required for a deployment', self.output)
        self.assertFalse(self.events('pull')); self.assertFalse(self.events('build-start'))
        self.assertFalse([e for e in self.events('docker') if e['host'] != 'local'])
        starts = lambda: [e['args'][-1] for e in self.events('powershell.exe') if 'Start-Process' in e['args'][-1]]
        self.assertFalse(starts())
        desktop = self.root / 'Docker Desktop.exe'; desktop.write_text('')
        (self.root / 'docker-state.json').unlink()
        self.clear_events()
        self.assert_ok(self.run_deploy(env={'FAIL_DOCKER_INFO': '1', 'DOCKER_DESKTOP_EXE': str(desktop)}))
        self.assertEqual(len(starts()), 1); self.assertIn('Docker Desktop.exe', starts()[0])
        self.assertTrue(self.manifest('deployed').exists())

    def test_docker_desktop_running_without_its_wsl_socket_is_restarted_not_started(self):
        desktop = self.root / 'Docker Desktop.exe'; desktop.write_text('')
        cli = self.bin / 'docker.exe'; shutil.copy2(KIT / 'tests/mock-command.py', cli); cli.chmod(0o755)
        detached = {'DOCKER_DESKTOP_EXE': str(desktop), 'DOCKER_DESKTOP_CLI': str(cli), 'DESKTOP_STATUS': 'running'}
        starts = lambda: [e for e in self.events('powershell.exe') if 'Start-Process' in e['args'][-1]]
        restarts = lambda: [e for e in self.events('docker-desktop') if e['args'] == ['desktop', 'restart']]
        # A restart would stop local containers: refuse at once, naming the fix, instead of waiting out the budget.
        self.assert_failed(self.run_deploy(skip_pull=False, env=dict(detached, FAIL_DOCKER_INFO='99', DESKTOP_CONTAINERS='0f1e2d3c')))
        self.assertIn('WSL integration is stopped', self.output); self.assertIn('Restart the WSL integration', self.output)
        self.assertFalse(restarts()); self.assertFalse(starts())
        self.assertFalse(self.events('pull')); self.assertFalse(self.events('build-start'))
        # Nothing running locally: restart Docker Desktop (starting it again is a no-op) and deploy.
        (self.root / 'docker-state.json').unlink(); self.clear_events()
        self.assert_ok(self.run_deploy(env=dict(detached, FAIL_DOCKER_INFO='1')))
        self.assertIn('restarting Docker Desktop', self.output)
        self.assertEqual(len(restarts()), 1); self.assertFalse(starts())
        self.assertTrue(self.manifest('deployed').exists())
        # Restarted and still no socket: the integration is off for this distro, not slow.
        (self.root / 'docker-state.json').unlink(); self.clear_events()
        self.assert_failed(self.run_deploy(env=dict(detached, FAIL_DOCKER_INFO='99', DOCKER_START_TIMEOUT='1')))
        self.assertIn('still has no docker.sock', self.output)
        self.assertEqual(len(restarts()), 1)

    def test_final_tier_is_checked_and_a_redirect_that_never_lands_is_not_healthy(self):
        self.assert_failed(self.run_deploy(env={'FAIL_HEALTH': 'fixture-service', 'HEALTH_CODE': '302'}))
        self.assertTrue(self.events('health', 'fixture-service'))
        self.assertFalse(self.manifest('deployed').exists())
        self.assertFalse(self.events('dns'))

    def test_a_front_door_that_redirects_to_its_page_is_healthy(self):
        self.assert_ok(self.run_deploy(env={'HEALTH_REDIRECT': 'fixture-service'}))
        self.assertTrue(all(row['follows'] for row in self.events('health', 'fixture-service')))
        self.assertTrue(self.manifest('deployed').exists())

    def test_docker_dying_before_the_build_is_retried_but_not_forever(self):
        self.assert_ok(self.run_deploy('--only=fixture-service', '--build-only',
                                       env={'FAIL_BUILD_CLI': 'fixture-service:1', 'BUILD_RETRY_DELAY': '0'}))
        self.assertEqual(len(self.events('build-cli-failure', 'fixture-service')), 1)
        self.assertEqual(len(self.events('build-end', 'fixture-service')), 1)
        self.assertIn('Docker died before building (attempt 1', self.output)
        self.assertTrue(self.manifest('built').exists())
        logs = list((self.kit / '.deploy-logs').glob('*/fixture-service.docker.log.attempt1'))
        self.assertIn('cannot allocate memory', logs[0].read_text())
        self.clear_events()
        docker_state = self.root / 'docker-state.json'
        docker_state.write_text(json.dumps({**json.loads(docker_state.read_text()), 'cli_failures': {}}))
        self.assert_failed(self.run_deploy('--only=fixture-service', '--build-only', '--no-cache',
                                           env={'FAIL_BUILD_CLI': 'fixture-service:3', 'BUILD_RETRY_DELAY': '0'}))
        self.assertEqual(len(self.events('build-cli-failure', 'fixture-service')), 3)
        self.assertFalse(self.events('build-start', 'fixture-service'))

    def test_failed_build_does_not_stop_or_remove_old_container(self):
        self.seed_source()
        self.assert_failed(self.run_deploy(env={'FAIL_BUILD': 'fixture-service'}))
        self.assertFalse(self.events('stop', 'fixture-service'))
        self.assertFalse(self.events('rm', 'fixture-service'))

    def test_migration_stops_old_after_transfer_and_removes_after_health(self):
        self.seed_source()
        self.assert_ok(self.run_deploy())
        events = self.events(service='fixture-service')
        indices = {name: next(i for i, e in enumerate(events) if e['event'] == name) for name in ['transfer', 'stop', 'restart', 'health', 'rm']}
        self.assertLess(indices['transfer'], indices['stop'])
        self.assertLess(indices['stop'], indices['restart'])
        self.assertLess(indices['health'], indices['rm'])
        self.assertTrue(self.manifest('deployed').exists())

    def test_failed_migration_restores_old_container(self):
        self.seed_source()
        self.assert_failed(self.run_deploy(env={'FAIL_HEALTH': 'fixture-service'}))
        self.assertTrue(self.events('start', 'fixture-service'))
        self.assertFalse(self.events('rm', 'fixture-service'))
        self.assertFalse(self.manifest('deployed').exists())
        data = json.loads((self.root / 'docker-state.json').read_text())
        self.assertTrue(data['containers']['mock-source']['fixture-service']['running'])
        self.assertFalse(data['containers']['mock-target']['fixture-service']['running'])

    def enable_remotes(self):
        for project in self.registry['projects']:
            name = project['id']; bare = self.root / (name + '.git')
            subprocess.check_call(['/usr/bin/git', 'init', '-q', '--bare', str(bare)])
            real_git(self.root / name, 'remote', 'add', 'origin', str(bare))
            real_git(self.root / name, 'push', '-qu', 'origin', 'main')

    def test_changed_only_pulls_before_comparing(self):
        self.enable_remotes()
        self.assert_ok(self.run_deploy())
        publisher = self.root / 'publisher'
        real_git(self.root / 'fixture-service', 'worktree', 'add', '--detach', str(publisher))
        (publisher / 'new.txt').write_text('remote change')
        real_git(publisher, 'add', 'new.txt'); real_git(publisher, 'commit', '-qm', 'remote update')
        real_git(publisher, 'push', 'origin', 'HEAD:main')
        self.clear_events()
        self.assert_ok(self.run_deploy('--changed-only', skip_pull=False))
        self.assertTrue(self.events('pull', 'fixture-service'))
        self.assertTrue(self.events('build-start', 'fixture-service'))
        self.assertTrue((self.root / 'fixture-service/new.txt').exists())

    def test_repository_pulls_are_bounded_and_sequential_mode_is_respected(self):
        self.add_service('extra-service'); self.add_service('another-service')
        self.save_registry(); self.enable_remotes()
        for flags, expected in [((), 2), (('--no-parallel',), 1)]:
            with self.subTest(flags=flags):
                self.clear_events()
                self.assert_ok(self.run_deploy('--build-only', *flags, skip_pull=False,
                    env={'MAX_CONCURRENT_SSH': '2', 'PULL_DELAY': '.2'}))
                active = maximum = 0
                for event in self.events():
                    if event['event'] == 'pull': active += 1
                    elif event['event'] == 'pull-ready': active -= 1
                    maximum = max(maximum, active)
                self.assertEqual(maximum, expected)
                self.assertEqual(active, 0)

    def test_new_transitive_library_is_pulled_after_dependency_graph_changes(self):
        self.add_library('utilities-library'); self.add_library('components-library')
        self.consumer_library('components-library'); self.enable_remotes()
        for library in ['components-library', 'utilities-library']:
            publisher = self.root / ('publisher-' + library)
            real_git(self.root / library, 'worktree', 'add', '--detach', str(publisher))
            if library == 'components-library':
                package = json.loads((publisher / 'package.json').read_text())
                package['dependencies']['@rodrigo-barraza/utilities-library'] = 'github:test/utilities-library'
                (publisher / 'package.json').write_text(json.dumps(package))
            else:
                (publisher / 'remote-update.txt').write_text('new transitive dependency revision')
            real_git(publisher, 'add', '.'); real_git(publisher, 'commit', '-qm', 'remote library update')
            real_git(publisher, 'push', 'origin', 'HEAD:main')
        self.assert_ok(self.run_deploy('--build-only', '--only=fixture-service', skip_pull=False))
        self.assertEqual(len(self.events('pull', 'utilities-library')), 1)
        self.assertTrue((self.root / 'utilities-library/remote-update.txt').exists())

    def test_failed_pull_aborts_before_build(self):
        self.enable_remotes()
        self.assert_failed(self.run_deploy(skip_pull=False, env={'FAIL_PULL': 'fixture-service'}))
        self.assertFalse(self.events('build-start'))

    def test_failed_dependency_steps_prevent_build(self):
        (self.root / 'fixture-service/pnpm-lock.yaml').write_text('lockfileVersion: 9')
        (self.root / 'fixture-service/package.json').write_text('{"dependencies":{"test-lib":"github:test/example"}}')
        for step in ['update', 'install', 'approve-builds']:
            with self.subTest(step=step):
                self.clear_events()
                self.assert_failed(self.run_deploy('--only=fixture-service', env={'FAIL_PNPM': step}))
                self.assertFalse(self.events('build-start', 'fixture-service'))

    def test_no_tests_directory_and_test_failure(self):
        (self.root / 'fixture-service/package.json').write_text('{"scripts":{"test":"vitest run"}}')
        self.assert_ok(self.run_deploy('--only=fixture-service', '--build-only', skip_tests=False))
        self.assertTrue(self.events('pnpm'))
        self.clear_events()
        self.assert_failed(self.run_deploy('--only=fixture-service', '--no-cache', skip_tests=False, env={'FAIL_PNPM': 'run'}))
        self.assertFalse(self.events('build-start'))

    def test_invalid_options_fail_before_any_external_action(self):
        for flag in ['--max-builds=0', '--max-builds=-1', '--max-builds=999999999999', '--max-builds=oops', '--dryrun', '--only=absent', '--skip=absent', '--group=absent', '--only=', '--only=fixture-service,']:
            with self.subTest(flag=flag):
                self.clear_events()
                self.assert_failed(self.run_deploy(flag))
                self.assertFalse(self.events())

    def test_killed_worker_is_failure_and_does_not_hang(self):
        self.assert_failed(self.run_deploy(env={'KILL_WORKER': 'vault-service'}))
        self.assertFalse(self.events('restart', 'fixture-service'))

    def test_build_timeout_is_failure(self):
        self.assert_failed(self.run_deploy('--only=fixture-service', '--build-only', env={'BUILD_DELAY': '30', 'BUILD_PHASE_TIMEOUT': '1'}))
        self.assertFalse(self.manifest('built').exists())

    def test_full_build_log_is_preserved_and_ticker_does_not_delay(self):
        start = time.monotonic()
        self.assert_failed(self.run_deploy('--only=fixture-service', '--build-only', env={'FAIL_BUILD': 'fixture-service'}))
        self.assertLess(time.monotonic() - start, 5)
        self.assertEqual(len(self.events('build-start', 'fixture-service')), 1)  # a real failure is not retried
        logs = list((self.kit / '.deploy-logs').glob('*/fixture-service.docker.log'))
        self.assertEqual(len(logs), 1)
        self.assertIn('MOCK_BUILD_LINE_1\n', logs[0].read_text())
        self.assertIn('MOCK_BUILD_LINE_15\n', logs[0].read_text())

    def test_cache_and_prune_are_bounded_and_compose_never_tears_down(self):
        self.assert_ok(self.run_deploy())
        self.assertFalse(self.events('compose-down'))
        docker = self.events('docker')
        local = [e for e in docker if e['host'] == 'local' and e['args'][:2] == ['image', 'prune']]
        remote = [e for e in docker if e['host'] == 'mock-target' and e['args'][:2] == ['image', 'prune']]
        self.assertEqual(len(local), 1); self.assertEqual(len(remote), 1)
        cache = next(e for e in docker if e['args'][:2] == ['builder', 'prune'] and '--help' not in e['args'])
        self.assertIn('--reserved-space', cache['args']); self.assertIn('20GB', cache['args'])
        for e in self.events('restart'): self.assertIn('--no-build', e['args'])

    def test_compose_failure_restores_local_env(self):
        before = (self.root / 'fixture-service/.env').read_bytes()
        self.assert_failed(self.run_deploy(env={'FAIL_RESTART': 'fixture-service'}))
        self.assertEqual(before, (self.root / 'fixture-service/.env').read_bytes())
        self.assertFalse(list((self.root / 'fixture-service').glob('.env.pre-deploy.*')))

    def test_killed_restart_worker_restores_local_env(self):
        before = (self.root / 'fixture-service/.env').read_bytes()
        self.assert_failed(self.run_deploy('--only=fixture-service', env={'KILL_RESTART_WORKER': 'fixture-service'}))
        self.assertEqual(before, (self.root / 'fixture-service/.env').read_bytes())
        self.assertFalse(list((self.root / 'fixture-service').glob('.env.pre-deploy.*')))
        self.assertFalse(self.manifest('deployed').exists())

    def test_standalone_workspace_wrapper_can_consume_its_custom_flag(self):
        self.add_service('workspace-service', hooks="""SKIP_TRAY_APP=false
for arg in "$@"; do
  case "$arg" in --skip-tray-app) SKIP_TRAY_APP=true ;; esac
done
""")
        self.assert_ok(self.run_command(['bash', str(self.root / 'workspace-service/deploy.sh'),
            '--dry-run', '--skip-tray-app']))
        self.assertFalse(self.events())

    def test_parallel_build_limit(self):
        self.add_service('extra-service', 1); self.save_registry()
        self.assert_ok(self.run_deploy('--max-builds=2', env={'BUILD_DELAY': '0.3'}))
        data = json.loads((self.root / 'docker-state.json').read_text())
        self.assertEqual(data['maximum'], 2)

    def test_sequential_mode_finishes_each_tier_before_later_builds(self):
        self.assert_ok(self.run_deploy('--no-parallel'))
        data = json.loads((self.root / 'docker-state.json').read_text())
        self.assertEqual(data['maximum'], 1)
        foundation_health = self.events('health', 'vault-service')[0]['time']
        dependent_build = self.events('build-start', 'fixture-service')[0]['time']
        self.assertLess(foundation_health, dependent_build)

    def test_lock_rejects_overlap_and_cancellation_stops_owned_children(self):
        command = ['bash', str(self.kit / 'deploy-all.sh'), '--skip-pull', '--skip-tests', '--ignore-temp-skip']
        first = subprocess.Popen(command, cwd=self.kit, env=dict(self.env, BUILD_DELAY='30'),
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try:
            deadline = time.monotonic() + 6
            while not self.events('build-start') and time.monotonic() < deadline: time.sleep(.05)
            self.assertTrue(self.events('build-start'))
            second = self.run_deploy()
            self.assert_failed(second)
            self.assertIn('Another deployment is running', second[1])
            first.terminate()
            first.communicate(timeout=8)
            self.assertNotEqual(first.returncode, 0)
            self.assertFalse(self.events('restart'))
            for event in self.events('build-start'):
                stat = Path('/proc') / str(event['pid']) / 'stat'
                if stat.exists(): self.assertEqual(stat.read_text().split(') ')[1][0], 'Z', 'Owned Docker child survived cancellation')
        finally:
            if first.poll() is None: os.killpg(first.pid, signal.SIGKILL); first.communicate()

    def test_env_or_source_change_requires_new_deployment(self):
        self.assert_ok(self.run_deploy())
        self.clear_events()
        (self.kit / '.env.deploy').write_text('EXAMPLE=updated\n')
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertTrue(self.events('build-start', 'fixture-service'))
        self.clear_events()
        (self.root / 'fixture-service/untracked.txt').write_text('new source')
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertTrue(self.events('build-start', 'fixture-service'))

    def test_project_in_a_subdirectory_of_another_repository(self):
        # A registry `dir` places a project inside a larger repository: it deploys
        # from there, is never pulled, and only its own directory and `sources`
        # count as its source.
        self.add_service('game', 1)
        crate = self.root / 'game/crates/svc'; crate.mkdir(parents=True)
        for name in ['Dockerfile', 'docker-compose.yml', '.env']:
            shutil.copy2(self.root / 'game' / name, crate / name)
        (crate / 'deploy.sh').write_text((self.root / 'game/deploy.sh').read_text()
            .replace('"game"', '"nested-service"')
            .replace('source "${SCRIPT_DIR}/../deploy-kit/lib.sh"',
                     'deploy_kit_path="${SCRIPT_DIR}/../../../deploy-kit"\nsource "$deploy_kit_path/lib.sh"'))
        (self.root / 'game/crates/shared').mkdir()
        (self.root / 'game/crates/shared/lib.txt').write_text('one')
        (self.root / 'game/crates/other.txt').write_text('one')
        self.commit('game', 'nested service')
        self.registry['projects'] = [p for p in self.registry['projects'] if p['id'] != 'game']
        self.enable_remotes()
        self.registry['projects'].append({'id': 'nested-service', 'dir': 'game/crates/svc', 'sources': ['crates/shared'],
            'deployTier': 1, 'deployTarget': 'target', 'port': 8100, 'healthPath': '/health/nested-service'})
        self.save_registry(); self.commit('vault-service', 'nested')
        self.assert_ok(self.run_deploy(skip_pull=False))
        self.assertTrue(self.events('build-start', 'nested-service'))
        self.assertTrue(self.events('pull', 'fixture-service'))
        self.assertFalse(self.events('pull', 'nested-service'))
        self.clear_events()
        (self.root / 'game/crates/other.txt').write_text('two'); self.commit('game', 'elsewhere')
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertFalse(self.events('build-start', 'nested-service'))
        (self.root / 'game/crates/shared/lib.txt').write_text('two'); self.commit('game', 'a source')
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertTrue(self.events('build-start', 'nested-service'))

    def test_untracked_nested_repository_is_not_source(self):
        self.assert_ok(self.run_deploy())
        self.clear_events()
        nested = self.root / 'fixture-service/.claude/worktrees/task'
        real_git(self.root / 'fixture-service', 'worktree', 'add', '--detach', str(nested))
        (nested / 'scratch.txt').write_text('sibling session work')
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertFalse(self.events('build-start', 'fixture-service'))

    def test_edge_sync_failure_does_not_erase_deployment_results(self):
        self.assert_ok(self.run_deploy(env={'FAIL_EDGE': '1'}))
        self.assertTrue(self.manifest('deployed').exists())
        self.assertIn('Edge DNS reconciliation failed', self.output)

    def add_library(self, name='utilities-library', dependencies=None):
        directory = self.root / name; (directory / 'src').mkdir(parents=True)
        (directory / 'package.json').write_text(json.dumps({'name':'@rodrigo-barraza/' + name, 'exports':{'.':'./dist/index.js'}, 'dependencies': dependencies or {}}))
        (directory / 'src/index.ts').write_text("export { used } from './used.js';\nexport { unused } from './unused.js';\n")
        (directory / 'src/used.ts').write_text('export const used = 1;\n')
        (directory / 'src/unused.ts').write_text('export const unused = 1;\n')
        real_git(directory, 'init', '-q', '-b', 'main')
        real_git(directory, 'config', 'user.name', 'Deployment Test')
        real_git(directory, 'config', 'user.email', 'test@example.invalid')
        self.commit(name)
        self.registry['projects'].append({'id':name, 'projectType':'Library'})
        self.save_registry()

    def consumer_library(self, name='utilities-library'):
        directory = self.root / 'fixture-service'
        (directory / 'package.json').write_text(json.dumps({'name':'fixture-service', 'dependencies':{'@rodrigo-barraza/' + name:'github:test/' + name}}))
        (directory / 'src').mkdir(exist_ok=True)
        (directory / 'src/index.ts').write_text("import { used } from '@rodrigo-barraza/" + name + "';\nconsole.log(used);\n")
        self.commit('fixture-service')

    def test_library_impact_uses_confirmed_target_state(self):
        self.add_library(); self.consumer_library()
        self.assert_ok(self.run_deploy())
        (self.root / 'utilities-library/src/unused.ts').write_text('export const unused = 2;\n')
        self.commit('utilities-library')
        self.clear_events()
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertFalse(self.events('restart', 'fixture-service'))
        (self.root / 'utilities-library/src/used.ts').write_text('export const used = 2;\n')
        self.commit('utilities-library')
        self.clear_events()
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertTrue(self.events('restart', 'fixture-service'))

    def test_skip_deps_does_not_certify_unknown_dependencies(self):
        self.add_library(); self.consumer_library()
        self.assert_ok(self.run_deploy('--skip-deps'))
        self.assertEqual(json.loads(self.manifest('built').read_text())['libraries'], {})
        self.clear_events()
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertTrue(self.events('build-start', 'fixture-service'))
        (self.root / 'utilities-library/src/used.ts').write_text('export const used = 2;\n')
        self.commit('utilities-library')
        self.clear_events()
        self.assert_ok(self.run_deploy('--changed-only', '--skip-deps'))
        self.assertFalse(self.events('build-start', 'fixture-service'))

    def test_failed_library_pull_blocks_builds(self):
        self.add_library(); self.consumer_library(); self.enable_remotes()
        self.assert_failed(self.run_deploy(skip_pull=False, env={'FAIL_PULL':'utilities-library'}))
        self.assertFalse(self.events('build-start'))

    def test_comment_is_not_a_circular_library_dependency(self):
        self.add_library('utilities-library')
        self.add_library('components-library', {'@rodrigo-barraza/utilities-library':'github:test/utilities-library'})
        (self.root / 'utilities-library/src/used.ts').write_text('// components-library uses this.\nexport const used = 1;\n')
        self.consumer_library('components-library')
        self.assert_ok(self.run_deploy('--dry-run'))

    def test_unknown_target_and_library_cycle_fail_before_actions(self):
        self.registry['projects'][1]['deployTarget'] = 'missing'
        self.save_registry()
        self.assert_failed(self.run_deploy())
        self.assertFalse(self.events())
        self.registry['projects'][1]['deployTarget'] = 'target'
        self.add_library('utilities-library', {'@rodrigo-barraza/components-library':'github:test/components-library'})
        self.add_library('components-library', {'@rodrigo-barraza/utilities-library':'github:test/utilities-library'})
        self.assert_failed(self.run_deploy())
        self.assertIn('Library dependency cycle', self.output)
        self.assertFalse(self.events())

    def test_worktree_runs_its_own_library_with_shared_configuration(self):
        real_git(self.kit, 'init', '-q', '-b', 'main')
        real_git(self.kit, 'config', 'user.name', 'Deployment Test')
        real_git(self.kit, 'config', 'user.email', 'test@example.invalid')
        real_git(self.kit, 'add', '.')
        real_git(self.kit, 'commit', '-qm', 'fixture kit')
        linked = self.root / 'kit worktree'
        real_git(self.kit, 'worktree', 'add', '--detach', str(linked))
        file = linked / 'lib.sh'
        file.write_text(file.read_text().replace('# ── Timer ', "info 'WORKTREE_LIBRARY_USED'\n# ── Timer ", 1))
        self.assert_ok(self.run_deploy('--build-only', kit=linked))
        self.assertIn('WORKTREE_LIBRARY_USED', self.output)
        self.assertTrue(self.manifest('built').exists())

    def test_legacy_wrapper_is_validated_before_its_full_deploy(self):
        (self.root / 'fixture-service/deploy.sh').write_text('''#!/bin/bash
for arg in "$@"; do if [ "$arg" = --dry-run ]; then exit 0; fi; done
docker -H mock-target compose up -d
''')
        self.assert_ok(self.run_deploy('--build-only', '--only=fixture-service'))
        self.assertFalse(self.events('restart'))
        self.assert_ok(self.run_deploy())
        self.assertTrue(self.events('restart', 'fixture-service'))
        self.assertTrue(self.manifest('deployed').exists())

    def test_source_change_during_build_does_not_advance_state(self):
        self.assert_failed(self.run_deploy('--only=fixture-service', '--build-only', env={'MUTATE_SOURCE':'fixture-service'}))
        self.assertFalse(self.manifest('built').exists())
        self.assertIn('inputs changed during its build', self.output)

    def test_standalone_dry_run_and_pull_failure(self):
        command = ['bash', str(self.root / 'fixture-service/deploy.sh')]
        self.assert_ok(self.run_command(command + ['--dry-run']))
        self.assertFalse(self.events())
        self.assert_failed(self.run_command(command + ['--build-only', '--skip-tests'], {'FAIL_PULL':'fixture-service'}))
        self.assertFalse(self.events('build-start'))

    def test_ssh_rollout_preserves_remote_health_format_argument(self):
        self.registry['devices'][0]['deploy'] = {'method': 'ssh', 'composeRoot': '/mock remote'}
        self.registry['devices'][0]['sshAlias'] = 'fake-nas'
        self.save_registry()
        self.assert_ok(self.run_deploy('--only=fixture-service'))
        checks = [event for event in self.events('docker', 'fixture-service')
                  if event['host'] == 'mock-target' and event['args'][0] == 'inspect']
        self.assertTrue(any(event['args'] == ['inspect', '--format',
            '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}',
            'fixture-service'] for event in checks), checks)
        self.assertTrue(self.manifest('deployed').exists())

    def test_ssh_failure_cannot_be_reported_as_successful_smb_export(self):
        self.registry['devices'][0]['deploy'] = {'method':'ssh', 'composeRoot':'/mock remote'}
        self.registry['devices'][0]['sshAlias'] = 'fake-nas'
        self.save_registry()
        self.assert_failed(self.run_deploy(env={'FAIL_SSH':'1'}))
        self.assertFalse(self.manifest('deployed').exists())
        self.assertFalse(self.events('restart'))

    def test_optional_cache_age_and_no_cache_forces_rebuild(self):
        self.assert_ok(self.run_deploy('--build-only', env={'BUILD_CACHE_MAX_AGE':'24h'}))
        cache = next(e for e in self.events('docker') if e['args'][:2] == ['builder','prune'] and '--help' not in e['args'])
        self.assertIn('until=24h', cache['args'])
        self.clear_events()
        self.assert_ok(self.run_deploy('--build-only', '--no-cache'))
        self.assertTrue(self.events('build-start'))

    def test_bot_final_tier_failure_is_reported(self):
        self.add_service('fixture-bot', 2); self.save_registry()
        self.assert_failed(self.run_deploy(env={'FAIL_HEALTH':'fixture-bot'}))
        self.assertTrue(self.events('health', 'fixture-bot'))
        self.assertFalse(self.manifest('deployed', 'fixture-bot').exists())

    def test_failed_rollout_then_reverted_source_still_retries(self):
        self.assert_ok(self.run_deploy())
        dockerfile = self.root / 'fixture-service/Dockerfile'
        original = dockerfile.read_text()
        dockerfile.write_text(original + 'LABEL changed=true\n')
        self.assert_failed(self.run_deploy('--changed-only', env={'FAIL_HEALTH':'fixture-service'}))
        self.assertTrue(self.manifest('pending').exists())
        dockerfile.write_text(original)
        self.clear_events()
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertTrue(self.events('restart', 'fixture-service'))
        self.assertFalse(self.manifest('pending').exists())

    def test_untested_cached_build_cannot_skip_tests_on_normal_build(self):
        (self.root / 'fixture-service/package.json').write_text('{"scripts":{"test":"vitest run"}}')
        self.assert_ok(self.run_deploy('--only=fixture-service', '--build-only'))
        self.clear_events()
        self.assert_ok(self.run_deploy('--only=fixture-service', '--build-only', skip_tests=False))
        self.assertTrue(self.events('pnpm'))
        self.assertTrue(self.events('build-start', 'fixture-service'))
        self.clear_events()
        self.assert_ok(self.run_deploy('--only=fixture-service', '--build-only', skip_tests=False))
        self.assertFalse(self.events('build-start'))

    def test_changed_only_explains_every_deployment(self):
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertIn('Deploying fixture-service — no deployment record', self.output)
        self.assertIn('2 of 2 selected services have no deployment record', self.output)
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertIn('Skipping fixture-service', self.output)
        self.assertNotIn('no deployment record', self.output)
        before = real_git(self.root / 'fixture-service', 'rev-parse', '--short=7', 'HEAD')
        (self.root / 'fixture-service/Dockerfile').write_text('FROM scratch\nLABEL v=2\n')
        self.commit('fixture-service')
        after = real_git(self.root / 'fixture-service', 'rev-parse', '--short=7', 'HEAD')
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertIn(f'Deploying fixture-service — source {before} → {after}', self.output)
        self.assertIn('Skipping vault-service', self.output)
        (self.root / 'fixture-service/untracked.txt').write_text('new source')
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertIn('Deploying fixture-service — working tree changed', self.output)
        (self.kit / '.env.deploy').write_text('EXAMPLE=updated\n')
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertIn('Deploying fixture-service — configuration changed', self.output)
        self.assertIn('Deploying vault-service — configuration changed', self.output)

    def test_library_change_is_named_and_a_lost_record_is_not_a_change(self):
        self.add_library(); self.consumer_library()
        self.assert_ok(self.run_deploy())
        (self.root / 'utilities-library/src/used.ts').write_text('export const used = 2;\n')
        self.commit('utilities-library')
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertRegex(self.output, r'Deploying fixture-service — library utilities-library [0-9a-f]{7} → [0-9a-f]{7}')
        self.manifest('deployed').unlink()
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertIn('Deploying fixture-service — no deployment record', self.output)
        self.assertIn('1 of 1 selected services have no deployment record', self.output)
        self.assertNotIn('Deploying vault-service', self.output)

    def test_unfinished_rollout_is_named_when_the_inputs_still_match(self):
        self.assert_ok(self.run_deploy())
        self.assert_failed(self.run_deploy(env={'FAIL_HEALTH': 'fixture-service'}))
        self.assertTrue(self.manifest('pending').exists())
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertIn('Deploying fixture-service — an earlier rollout did not finish', self.output)

    def test_legacy_markers_are_announced_and_retired_by_the_first_record(self):
        state = self.kit / '.deploy-state'; state.mkdir()
        for service in ['vault-service', 'fixture-service']:
            (state / f'{service}.sha').write_text(real_git(self.root / service, 'rev-parse', 'HEAD') + '\n')
        (state / 'fixture-service.deps.sha').write_text('utilities-library: 0000000\n')
        self.assert_failed(self.run_deploy('--changed-only', env={'FAIL_HEALTH': 'vault-service'}))
        self.assertIn('3 legacy .sha marker files', self.output)
        self.assertTrue((state / 'fixture-service.sha').exists())
        self.assertFalse(self.manifest('deployed', 'vault-service').exists())
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertIn('Deploying fixture-service — no deployment record', self.output)
        for marker in ['vault-service.sha', 'fixture-service.sha', 'fixture-service.deps.sha']:
            self.assertFalse((state / marker).exists(), marker)
        self.assert_ok(self.run_deploy('--changed-only'))
        self.assertNotIn('legacy .sha', self.output)
        self.assertIn('Skipping fixture-service', self.output)

    def test_cancellation_during_pull_stops_the_git_process(self):
        command = ['bash', str(self.kit / 'deploy-all.sh'), '--skip-tests', '--ignore-temp-skip']
        process = subprocess.Popen(command, cwd=self.kit, env=dict(self.env, PULL_DELAY='30'),
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try:
            deadline = time.monotonic() + 6
            while not self.events('pull') and time.monotonic() < deadline: time.sleep(.05)
            self.assertTrue(self.events('pull'))
            process.terminate()
            process.communicate(timeout=6)
            self.assertNotEqual(process.returncode, 0)
            for event in self.events('pull'):
                stat = Path('/proc') / str(event['pid']) / 'stat'
                if stat.exists(): self.assertEqual(stat.read_text().split(') ')[1][0], 'Z')
        finally:
            if process.poll() is None: os.killpg(process.pid, signal.SIGKILL); process.communicate()

if __name__ == '__main__': unittest.main()
