#!/usr/bin/env python3
"""Provision an Imager-prepared boot partition, or stage a current-Pi migration."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import tempfile
import uuid


def prepare(destination, stage=False, receipt_path=None, before_commit=None):
    if receipt_path is None: raise ValueError("--receipt 저장 경로가 필요합니다.")
    receipt_path = Path(receipt_path).resolve()
    if receipt_path.exists(): raise ValueError("기존 등록 정보 파일을 덮어쓰지 않습니다.")
    source = Path(__file__).resolve().parent
    destination = Path(destination).resolve()
    if not destination.is_dir(): raise ValueError('SD 부팅 파티션을 선택하세요.')
    command_path = destination / 'cmdline.txt'
    if not stage and (not command_path.is_file() or not (destination / 'config.txt').is_file()):
        raise ValueError('Raspberry Pi Imager로 준비한 bootfs 파티션이 아닙니다.')
    target = destination / 'vgf-controller'
    if target.exists(): raise ValueError('이 SD에는 이미 파이 등록 정보가 있습니다. 기존 등록 정보를 사용하세요.')
    original = command_path.read_text() if not stage else ''
    config_path = destination / 'config.txt'
    original_config = config_path.read_text() if not stage else ''
    arguments = shlex.split(original)
    previous = [v.split('=', 1)[1] for v in arguments if v.startswith('systemd.run=')]
    if len(previous) > 1 or (previous and not previous[0].startswith('/boot/')):
        raise ValueError('기존 첫 부팅 설정을 확인할 수 없어 SD를 변경하지 않았습니다.')
    device_id = str(uuid.uuid4())
    pin = f'{secrets.randbelow(1000000):06d}'
    with tempfile.TemporaryDirectory(prefix='vgf-provision-') as temporary:
        payload = Path(temporary) / 'payload'; payload.mkdir()
        shutil.copytree(source / 'native', payload / 'native', ignore=shutil.ignore_patterns('*.o', 'vgf-controller', 'test-protocol', 'test-auth', 'test-session', 'test-serial'))
        for name in ['install.sh', 'install_identity.py']:
            shutil.copy2(source / name, payload / name)
        shutil.copytree(source / 'vendor', payload / 'vendor', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        config = payload / 'identity'; config.mkdir(mode=0o700)
        subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650',
                        '-keyout', str(config / 'server.key'), '-out', str(config / 'server.crt'),
                        '-subj', '/CN=vgf-' + device_id], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        der = subprocess.check_output(['/usr/bin/openssl', 'x509', '-in', str(config / 'server.crt'), '-outform', 'DER'])
        identity = {'id': device_id, 'secret': secrets.token_hex(32),
                    'pin_hash': hashlib.sha256((device_id + ':' + pin).encode()).hexdigest(), 'paired': False}
        (config / 'device.json').write_text(json.dumps(identity))
        for p in config.iterdir(): p.chmod(0o600)
        receipt = {'id': device_id, 'name': 'Video Game Filter Pi', 'fingerprint': hashlib.sha256(der).hexdigest(),
                   'client': str(uuid.uuid4()), 'pin': pin}
        names = ['vgf-controller', 'vgf-firstboot.sh', 'vgf-previous-run.txt', 'vgf-cmdline-original.txt', 'cmdline.txt.vgf-serial-backup']
        if any((destination / name).exists() for name in names):
            raise ValueError('기존 준비 파일이 있습니다.')
        receipt_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(receipt_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as f:
            json.dump(receipt, f); f.flush(); os.fsync(f.fileno())
        try:
            shutil.copytree(payload, target)
            if not stage:
                shutil.copy2(source / 'firstboot.sh', destination / 'vgf-firstboot.sh')
                if previous: (destination / 'vgf-previous-run.txt').write_text(previous[0])
                (destination / 'vgf-cmdline-original.txt').write_text(original)
                rollback_words = [v for v in arguments if not v.startswith(('systemd.run=', 'systemd.run_success_action=', 'systemd.unit='))]
                (destination / 'cmdline.txt.vgf-serial-backup').write_text(' '.join(rollback_words) + '\n')
                updated = [v for v in arguments if not v.startswith(('systemd.run=', 'systemd.run_success_action=', 'systemd.unit=', 'console=serial0,'))]
                updated += ['systemd.run=/boot/firmware/vgf-firstboot.sh', 'systemd.run_success_action=reboot', 'systemd.unit=kernel-command-line.target']
                settings = []
                if 'dtoverlay=dwc2,dr_mode=peripheral' not in original_config.splitlines():
                    settings.append('dtoverlay=dwc2,dr_mode=peripheral')
                if 'enable_uart=1' not in original_config.splitlines(): settings.append('enable_uart=1')
                if 'core_freq=250' not in original_config.splitlines(): settings.append('core_freq=250')
                if settings: config_path.write_text(original_config + '\n[all]\n# Video Game Filter USB controller\n' + '\n'.join(settings) + '\n')
                if before_commit: before_commit()
                command_path.write_text(' '.join(updated) + '\n')
        except Exception:
            if not stage:
                command_path.write_text(original)
                config_path.write_text(original_config)
            for name in names:
                path = destination / name
                if path.is_dir(): shutil.rmtree(path)
                elif path.exists(): path.unlink()
            receipt_path.unlink(missing_ok=True)
            raise
        return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('destination')
    parser.add_argument('--stage', action='store_true')
    parser.add_argument('--receipt', required=True)
    args = parser.parse_args()
    try:
        prepare(args.destination, args.stage, args.receipt)
        print('Private registration receipt saved to ' + args.receipt)
    except Exception as error:
        import sys
        print(str(error), file=sys.stderr); sys.exit(1)
