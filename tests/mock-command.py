#!/usr/bin/python3
"""Network/process boundary for deploy integration tests; no live tools are called."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import shlex
import signal
import sys
import time

cmd = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ['TEST_ROOT'])

def event(name, **data):
    entry = dict(event=name, time=time.monotonic(), pid=os.getpid(), **data)
    fd = os.open(root / 'events.jsonl', os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(fd, (json.dumps(entry) + '\n').encode())
    os.close(fd)

@contextlib.contextmanager
def state():
    with open(root / 'docker-state.json', 'a+') as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        file.seek(0)
        value = json.loads(file.read() or '{"images":{},"containers":{},"builds":0,"active":0,"maximum":0}')
        yield value
        file.seek(0); file.truncate(); json.dump(value, file); file.flush()

if cmd == 'node':
    if args and args[0].endswith('/edge/reconcile-dns.js'):
        event('dns', args=args)
        print('1 in place, 0 created, 0 pruned')
        sys.exit(int(os.environ.get('FAIL_EDGE', '0')))
    os.execv(os.environ['REAL_NODE'], [os.environ['REAL_NODE'], *args])
if cmd == 'git':
    if 'pull' in args:
        directory = args[args.index('-C') + 1] if '-C' in args else os.getcwd()
        service = Path(directory).name
        event('pull', service=service)
        time.sleep(float(os.environ.get('PULL_DELAY', '0')))
        event('pull-ready', service=service)
        if os.environ.get('FAIL_PULL') == service:
            print('mock pull failure', file=sys.stderr); sys.exit(18)
    os.execv('/usr/bin/git', ['/usr/bin/git', *args])
if cmd == 'pnpm':
    event('pnpm', args=args, service=Path.cwd().name)
    if os.environ.get('FAIL_PNPM') == args[0]:
        print('mock pnpm failure', file=sys.stderr); sys.exit(19)
    sys.exit(0)
if cmd in ('ssh-add', 'ssh-agent', 'powershell.exe'):
    event(cmd, args=args)
    sys.exit(0)
if cmd == 'docker.exe':
    # Docker Desktop's Windows CLI, with its CRLF output. DESKTOP_STATUS=running|stopped,
    # DESKTOP_CONTAINERS=<ids> — what `ps -q` lists on the Desktop engine.
    event('docker-desktop', args=args)
    if args[:2] == ['desktop', 'status']:
        sys.stdout.write('Name                Value\r\nStatus              ' + os.environ.get('DESKTOP_STATUS', 'stopped') + '\r\n')
    elif 'ps' in args and os.environ.get('DESKTOP_CONTAINERS'):
        sys.stdout.write(os.environ['DESKTOP_CONTAINERS'] + '\r\n')
    sys.exit(0)
if cmd == 'curl':
    service = args[-1].rsplit('/', 1)[-1]
    event('health', service=service, follows='-L' in args)
    if os.environ.get('FAIL_HEALTH') == service: print(os.environ.get('HEALTH_CODE', '503'), end='')
    # HEALTH_REDIRECT: the front door answers 307 to its page; only a follower sees the 200.
    elif os.environ.get('HEALTH_REDIRECT') == service and '-L' not in args: print('307', end='')
    else: print('200', end='')
    sys.exit(0)
if cmd == 'ssh':
    event('ssh', args=args)
    if os.environ.get('FAIL_SSH') == '1': sys.exit(255)
    remote_index = 0
    while remote_index < len(args) and args[remote_index].startswith('-'):
        remote_index += 2 if args[remote_index] in ('-o', '-p', '-i', '-F') else 1
    # OpenSSH joins command arguments before passing them to the remote shell.
    remote = ' '.join(args[remote_index + 1:])
    if 'cat >' in remote:
        sys.stdin.buffer.read()
        sys.exit(22 if os.environ.get('FAIL_SYNC') == '1' else 0)
    lexer = shlex.shlex(remote, posix=True, punctuation_chars='|&;<>')
    lexer.whitespace_split = True
    parts = list(lexer)
    docker_index = next((i for i, value in enumerate(parts) if value.endswith('/docker') or value == 'docker'), None)
    if docker_index is None: sys.exit(0)
    args = parts[docker_index + 1:]
    if args and args[0] == 'inspect' and '|' in args:
        print('unquoted Docker format interpreted as a shell pipeline', file=sys.stderr)
        sys.exit(2)
    os.environ['DOCKER_HOST'] = 'mock-target'
    cmd = 'docker'
if cmd != 'docker':
    raise RuntimeError(f'Unexpected mock: {cmd}')
host = os.environ.get('DOCKER_HOST', 'local')
if '-H' in args:
    index = args.index('-H'); host = args[index + 1]; del args[index:index + 2]
service = os.environ.get('DEPLOY_SERVICE_ID', Path.cwd().name)
event('docker', args=args, host=host, service=service)
if args[:1] == ['info'] and host == 'local':
    # FAIL_DOCKER_INFO=<n> — the local daemon is down for the first n checks.
    with state() as data:
        checks = data.get('info_checks', 0); data['info_checks'] = checks + 1
    if checks < int(os.environ.get('FAIL_DOCKER_INFO', '0')):
        print('failed to connect to the docker API at unix:///var/run/docker.sock', file=sys.stderr); sys.exit(1)
    sys.exit(0)
if args == ['builder', 'prune', '--help']:
    print('      --reserved-space bytes   Amount of disk space always allowed to keep for cache'); sys.exit(0)
if args[:2] == ['buildx', 'build']:
    if '-t' in args: service = args[args.index('-t') + 1].split(':')[0]
    # FAIL_BUILD_CLI=<service>:<n> — the docker CLI dies n times before the daemon builds anything.
    cli_service, _, cli_count = os.environ.get('FAIL_BUILD_CLI', '').partition(':')
    if cli_service == service:
        with state() as data:  # exit outside the block, or the counter is never written back
            failures = data.setdefault('cli_failures', {}).get(service, 0)
            cli_dies = failures < int(cli_count or 1)
            if cli_dies: data['cli_failures'][service] = failures + 1
        if cli_dies:
            event('build-cli-failure', service=service)
            print('ERROR: readdirent /home/mock/.docker/contexts/meta: cannot allocate memory')
            sys.exit(1)
    with state() as data:
        data['active'] += 1; data['maximum'] = max(data['maximum'], data['active'])
    event('build-start', service=service)
    if os.environ.get('KILL_WORKER') == service:
        os.kill(os.getsid(0), signal.SIGKILL)
        time.sleep(30)
    time.sleep(float(os.environ.get('BUILD_DELAY', '0.02')))
    if os.environ.get('MUTATE_SOURCE') == service:
        (root / service / 'changed-during-build.txt').write_text('unexpected source edit')
    for line in range(1, 16): print(f'MOCK_BUILD_LINE_{line}')
    failed = os.environ.get('FAIL_BUILD') == service
    with state() as data:
        data['active'] -= 1
        if not failed:
            data['builds'] += 1
            data['images'][service] = f'sha256:image-{data["builds"]}'
    event('build-end', service=service, failed=failed)
    sys.exit(7 if failed else 0)
if args[:2] == ['image', 'inspect']:
    with state() as data: image = data['images'].get(args[-1].split(':')[0])
    if not image: sys.exit(1)
    print(image); sys.exit(0)
if args and args[0] == 'inspect' and any('RestartPolicy' in arg for arg in args):
    # The restart-policy pin reads each stack container's policy: the service
    # itself (unless-stopped, as the compose files say, until updated) and a
    # STACK_JOB=<service>:<name> one-shot job the compose file gave `no`.
    names = [arg for arg in args[1:] if not arg.startswith('--') and 'RestartPolicy' not in arg]
    with state() as data:
        containers = data['containers'].get(host, {})
        for name in names:
            if name not in containers: sys.exit(1)
            print(f"/{name} {containers[name].get('restart', 'unless-stopped')}")
    sys.exit(0)
if args and args[0] == 'update':
    policy = next(arg.split('=', 1)[1] for arg in args if arg.startswith('--restart='))
    names = [arg for arg in args[1:] if not arg.startswith('--')]
    event('update', host=host, args=args, names=names)
    with state() as data:
        containers = data['containers'].get(host, {})
        for name in names: containers[name]['restart'] = policy
    sys.exit(0)
if args and args[0] == 'inspect':
    if host == 'local': sys.exit(1)  # no previous git.sha label; exercise host sync
    status = not any('{{.Image}}' in arg or 'Healthcheck' in arg for arg in args)
    with state() as data:
        container = data['containers'].get(host, {}).get(args[-1])
        if not container: sys.exit(1)
        starting = container.get('running') and container.get('starting', 0) > 0
        if starting and status: container['starting'] -= 1
    if '{{.Image}}' in args: print('sha256:previous-container')
    elif any('Healthcheck' in arg for arg in args): print('["CMD","wget","-qO-","http://localhost/health"]')
    elif starting: print('true|starting')
    else: print('true|healthy' if container.get('running') else 'false|')
    sys.exit(0)
if args and args[0] == 'exec':
    # The container's own health test, run by the restart gate. PROBE_FAILS=<service>
    # is an app still booting: its test fails until Docker's own probe says healthy.
    name = args[1]
    event('probe', service=name, host=host, args=args[2:])
    with state() as data: container = data['containers'].get(host, {}).get(name, {})
    healthy = container.get('running') and os.environ.get('PROBE_FAILS') != name
    sys.exit(0 if healthy else 1)
if args and args[0] == 'save':
    print(args[1].split(':')[0]); sys.exit(0)
if args and args[0] == 'load':
    # API loads use gzip output; content isn't needed to validate orchestration.
    sys.stdin.buffer.read()
    event('transfer', service=service, host=host)
    sys.exit(9 if os.environ.get('FAIL_TRANSFER') == service else 0)
if args and args[0] == 'compose':
    if 'down' in args:
        event('compose-down', service=service, host=host)
    if 'up' in args:
        event('restart', service=service, host=host, args=args)
        if os.environ.get('KILL_RESTART_WORKER') == service:
            os.kill(os.getsid(0), signal.SIGKILL)
            time.sleep(30)
        if os.environ.get('FAIL_RESTART') == service: sys.exit(10)
        # STARTING_PROBES=<service>:<n> — Docker's first health probe runs one
        # interval after start; the new container answers `starting` n times.
        probes = os.environ.get('STARTING_PROBES', '').split(':')
        starting = int(probes[1]) if probes[0] == service else 0
        with state() as data:
            data['containers'].setdefault(host, {})[service] = {'running': True, 'starting': starting}
            job_service, _, job = os.environ.get('STACK_JOB', '').partition(':')
            if job_service == service:
                data['containers'][host][job] = {'running': False, 'restart': 'no'}
    elif 'ps' in args:
        job_service, _, job = os.environ.get('STACK_JOB', '').partition(':')
        with state() as data: containers = data['containers'].get(host, {})
        print('\n'.join(name for name in [service, job if job_service == service else None] if name and name in containers))
    sys.exit(0)
if args and args[0] == 'ps':
    with state() as data: containers = dict(data['containers'].get(host, {}))
    if '--filter' in args:
        wanted = args[args.index('--filter') + 1].removeprefix('name=^/').removesuffix('$')
        containers = {key: value for key, value in containers.items() if key == wanted}
    print('\n'.join(containers)); sys.exit(0)
if args and args[0] in ('stop', 'start', 'rm'):
    operation, name = args[0], args[-1]
    event(operation, service=name, host=host)
    with state() as data:
        containers = data['containers'].setdefault(host, {})
        if name not in containers: sys.exit(1)
        if operation == 'rm':
            if containers[name].get('running'): sys.exit(1)
            if os.environ.get('FAIL_REMOVE') == name: sys.exit(1)
            del containers[name]
        else: containers[name]['running'] = operation == 'start'
    sys.exit(0)
if args and args[0] == 'images':
    sys.exit(0)
sys.exit(0)
