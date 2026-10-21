#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import datetime
import grp
import os
from pathlib import Path
import platform
import pwd
import re
import secrets
import shlex
import shutil
import struct
import subprocess
import sys
import time
import urllib.request

ORIGIN = 'https://123.56.147.51:8443'
SOURCE = Path(__file__).resolve().parent.parent

def read_env(path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, separator, value = line.partition('=')
        if not separator or not re.fullmatch(r'[A-Z][A-Z0-9_]*', key):
            raise ValueError(f'Unsupported environment line in {path}')
        parsed = shlex.split(value, comments=False)
        if len(parsed) > 1:
            raise ValueError(f'Quote values containing spaces in {path}: {key}')
        values[key] = parsed[0] if parsed else ''
    return values

def write_env(path, values, gid):
    temporary = path.with_name(path.name + '.' + secrets.token_hex(8) + '.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as file:
            file.write(''.join(f'{key}={shlex.quote(value)}\n' for key, value in values.items()))
            file.flush()
            os.fsync(file.fileno())
        os.chown(temporary, 0, gid)
        temporary.chmod(0o640)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)

def verify_binary(path):
    with path.open('rb') as file:
        header = file.read(20)
    if len(header) != 20 or header[:4] != b'\x7fELF' or header[5] not in (1, 2):
        raise ValueError(f'{path} is not a Linux ELF binary; build on the target NAS')
    machine = struct.unpack('<H' if header[5] == 1 else '>H', header[18:20])[0]
    expected = {'x86_64': 62, 'aarch64': 183, 'arm64': 183, 'armv7l': 40, 'riscv64': 243}.get(platform.machine())
    if expected is None or expected != machine:
        raise ValueError(f'{path} does not match NAS architecture {platform.machine()}')
    libraries = subprocess.run(['ldd', str(path)], text=True, capture_output=True)
    if 'not found' in libraries.stdout or 'not found' in libraries.stderr:
        raise ValueError(f'Missing runtime libraries for {path}: {libraries.stdout}{libraries.stderr}')

def verify_defaults(path, expected_key):
    if b'SE9_NAS_EMBEDDED_CONFIG_V2' not in path.read_bytes():
        raise ValueError(f'{path} is an old build without embedded deployment defaults')
    environment = dict(os.environ)
    environment.pop('SE9_CLOUD_GRANT_PUBLIC_KEY', None)
    process = subprocess.run([str(path), '--config-info'], env=environment, text=True, capture_output=True, timeout=10)
    try:
        info = json.loads(process.stdout)
    except ValueError:
        raise ValueError(f'{path} is an old build without embedded deployment defaults') from None
    if process.returncode or info.get('configVersion') != 2 or info.get('cloudOrigin') != ORIGIN or info.get('cloudPublicKeySha256') != expected_key:
        raise ValueError(f'{path} has an unexpected cloud address/key; rebuild from this checkout')
    if path.name == 'se9_agent' and info.get('rtcCompiled') is not True:
        raise ValueError('Build with SE9_WEBRTC=ON before installing the WebRTC NAS')

def run(*arguments):
    return subprocess.run(arguments, check=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=SOURCE / 'build/se9-c')
    parser.add_argument('--storage-root', type=Path)
    parser.add_argument('--no-start', action='store_true')
    args = parser.parse_args()
    if platform.system() != 'Linux' or os.geteuid() != 0:
        parser.error('Run with sudo on a Linux NAS with systemd')
    if not Path('/run/systemd/system').exists():
        parser.error('A running systemd system is required')
    pem = (SOURCE / 'deploy/cloud-grant-public.pem').read_text()
    expected_key = hashlib.sha256(base64.b64decode(''.join(line for line in pem.splitlines() if not line.startswith('-----')))).hexdigest()
    for name in ('se9_agent', 'se9_file_api'):
        binary = args.build_dir.resolve() / name
        verify_binary(binary)
        verify_defaults(binary, expected_key)
    agent_path, api_path = Path('/etc/se9/se9-agent.env'), Path('/etc/se9/se9-file-api.env')
    agent, api = read_env(agent_path), read_env(api_path)
    storage = args.storage_root or Path(api.get('STORAGE_ROOT', '/vos/workspace/demo'))
    if not storage.is_absolute() or any(c in str(storage) for c in '\r\n\x00'):
        parser.error('Storage root must be an absolute path without control characters')
    api_port, agent_port = api.get('FILE_API_PORT'), agent.get('FILE_API_PORT')
    if api_port and agent_port and api_port != agent_port:
        parser.error('Existing Agent and File API ports differ; correct them before installing')
    port = api_port or agent_port or '8443'
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        parser.error('Invalid File API port')
    tokens = {value for value in (agent.get('SE9_AGENT_PROXY_TOKEN', ''), api.get('SE9_AGENT_PROXY_TOKEN', '')) if value and not value.startswith('replace-')}
    if len(tokens) > 1:
        parser.error('Existing Agent and File API proxy keys differ; refusing to replace either')
    token_files = {value for value in (agent.get('SE9_AGENT_PROXY_TOKEN_FILE', ''), api.get('SE9_AGENT_PROXY_TOKEN_FILE', '')) if value}
    if len(token_files) > 1:
        parser.error('Existing proxy key file paths differ')
    token_file = next(iter(token_files), '/var/lib/se9/agent-proxy-token')
    if not tokens and token_file != '/var/lib/se9/agent-proxy-token':
        parser.error('Custom proxy key files require manual ownership/path verification')
    identity = agent.get('SE9_KEY_FILE')
    if not identity:
        candidates = [path for path in ('/var/lib/se9/device-ed25519.pem', '/var/lib/se9/device.key') if Path(path).exists()]
        if len(candidates) > 1:
            parser.error('Multiple device identities exist; set SE9_KEY_FILE before upgrading')
        identity = candidates[0] if candidates else '/var/lib/se9/device-ed25519.pem'
    try:
        account = pwd.getpwnam('se9')
    except KeyError:
        run('useradd', '--system', '--user-group', '--home-dir', '/var/lib/se9', '--shell', '/usr/sbin/nologin', 'se9')
        account = pwd.getpwnam('se9')
    try:
        group = grp.getgrnam('se9')
    except KeyError:
        raise ValueError('Existing se9 account requires a se9 primary group') from None
    if group.gr_gid != account.pw_gid:
        raise ValueError('Existing se9 account must use se9 as its primary group')
    for path in (Path('/var/lib/se9'), Path('/var/log/se9'), storage):
        if not path.exists():
            path.mkdir(mode=0o750, parents=True)
            os.chown(path, account.pw_uid, account.pw_gid)
        run('runuser', '-u', 'se9', '--', 'test', '-w', str(path))
    for path in (Path('/opt/se9'), Path('/etc/se9')):
        path.mkdir(mode=0o750 if path.name == 'se9' and str(path).startswith('/etc/') else 0o755, parents=True, exist_ok=True)
    os.chown('/etc/se9', 0, account.pw_gid)
    backup = Path('/var/backups/se9-nas') / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + secrets.token_hex(3))
    backup.mkdir(mode=0o700, parents=True)
    for path in (agent_path, api_path, Path('/opt/se9/se9_agent'), Path('/opt/se9/se9_file_api'), Path('/etc/se9/cloud-grant-public.pem')):
        if path.exists():
            shutil.copy2(path, backup / path.name)
    agent.update({'SE9_CLOUD_URL': ORIGIN, 'SE9_CLOUD_BASE_PATH': '/se9', 'SE9_RTC_ENABLED': '1', 'SE9_RTC_ALLOW_INSECURE_LOCAL': '0', 'SE9_TLS_INSECURE': '0', 'SE9_KEY_FILE': identity, 'SE9_TOKEN_FILE': agent.get('SE9_TOKEN_FILE', '/var/lib/se9/device-token'), 'FILE_API_PORT': port})
    agent.pop('SE9_FILE_API_URL', None)
    agent.pop('SE9_CLOUD_GRANT_PUBLIC_KEY', None)
    api.update({'STORAGE_ROOT': str(storage), 'FILE_API_PORT': port, 'FILE_API_BIND_ADDR': api.get('FILE_API_BIND_ADDR', '127.0.0.1')})
    if not api.get('DEMO_ADMIN_PASSWORD') or api['DEMO_ADMIN_PASSWORD'] == 'change-me' or api['DEMO_ADMIN_PASSWORD'].startswith('replace-'):
        api['DEMO_ADMIN_PASSWORD'] = secrets.token_hex(32)
    for values in (agent, api):
        if tokens:
            values['SE9_AGENT_PROXY_TOKEN'] = next(iter(tokens))
        else:
            values.pop('SE9_AGENT_PROXY_TOKEN', None)
            values['SE9_AGENT_PROXY_TOKEN_FILE'] = token_file
    for name in ('se9_agent', 'se9_file_api'):
        destination = Path('/opt/se9') / name
        temporary = destination.with_name(name + '.new')
        shutil.copyfile(args.build_dir.resolve() / name, temporary)
        temporary.chmod(0o755)
        os.chown(temporary, 0, 0)
        os.replace(temporary, destination)
    public = Path('/etc/se9/cloud-grant-public.pem')
    shutil.copyfile(SOURCE / 'deploy/cloud-grant-public.pem', public)
    public.chmod(0o644)
    os.chown(public, 0, account.pw_gid)
    write_env(agent_path, agent, account.pw_gid)
    write_env(api_path, api, account.pw_gid)
    for name in ('se9-agent.service', 'se9-file-api.service'):
        destination = Path('/etc/systemd/system') / name
        if destination.exists():
            shutil.copy2(destination, backup / name)
        shutil.copyfile(SOURCE / 'deploy' / name, destination)
        destination.chmod(0o644)
    dropin = Path('/etc/systemd/system/se9-file-api.service.d/storage.conf')
    dropin.parent.mkdir(parents=True, exist_ok=True)
    escaped = str(storage).replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
    dropin.write_text('[Service]\nReadWritePaths=\nReadWritePaths=/var/lib/se9 /var/log/se9 "' + escaped + '"\n')
    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', 'se9-file-api.service', 'se9-agent.service')
    if not args.no_start:
        run('systemctl', 'restart', 'se9-file-api.service')
        for attempt in range(30):
            try:
                with urllib.request.urlopen('http://127.0.0.1:' + port + '/api/v2/health', timeout=1) as response:
                    if response.status == 200:
                        break
            except OSError:
                pass
            time.sleep(0.2)
        else:
            raise RuntimeError('File API health check failed; inspect journalctl -u se9-file-api')
        run('systemctl', 'restart', 'se9-agent.service')
        time.sleep(1)
        run('systemctl', 'is-active', 'se9-file-api.service', 'se9-agent.service')
    print('Installed NAS services; cloud address and public key configured. Backup:', backup)
    print('Device identity preserved; local proxy key is reused or generated on first service start.')

if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print('NAS installation failed:', error, file=sys.stderr)
        sys.exit(1)
