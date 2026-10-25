"""Local IP-pool operator. Plans are explicit; no unimplemented apply command."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import sys
import time
import shutil
import subprocess
import ip_pool
from installer import atomic

ROOT = Path('/var/lib/whalenode-installer')


def install_watch():
    """Install only the local discovery timer, never a privileged panel token."""
    destination=Path('/opt/whalenode/ip-pool')
    files=('installer.py','ip_pool.py','ip_pool_cli.py','ip_pool_transaction.py')
    source=Path(__file__).resolve().parent
    # Validate all inputs before making any installation changes.
    content={name:(source/name).read_text(encoding='utf8') for name in files}
    destination.mkdir(parents=True,exist_ok=True,mode=0o700)
    for name,body in content.items():atomic(destination/name,body)
    unit='''[Unit]
Description=WhaleNode public IPv4 discovery (no automatic publication)
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/whalenode/ip-pool/ip_pool_cli.py scan
UMask=0077
Environment=PYTHONDONTWRITEBYTECODE=1
CPUQuota=20%
MemoryMax=128M
TasksMax=16
TimeoutStartSec=600
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/whalenode-installer
'''
    timer='''[Unit]
Description=Check WhaleNode public IPv4 pool after boot and every five minutes
[Timer]
OnBootSec=3min
OnUnitInactiveSec=5min
RandomizedDelaySec=15s
Unit=whalenode-ip-pool.service
[Install]
WantedBy=timers.target
'''
    atomic('/etc/systemd/system/whalenode-ip-pool.service',unit,0o644)
    atomic('/etc/systemd/system/whalenode-ip-pool.timer',timer,0o644)
    subprocess.run(['systemctl','daemon-reload'],check=True,timeout=30)
    subprocess.run(['systemctl','enable','--now','whalenode-ip-pool.timer'],check=True,timeout=30)


@contextlib.contextmanager
def locked(root):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (root/'lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('安装或 IP 管理任务正在执行，请稍后重试') from None
        yield


def load(root):
    path = root/'ip-pool.json'
    if path.exists():
        result = json.loads(path.read_text())
        if result.get('schema') != 1:
            raise ValueError('地址池版本不兼容')
        return result
    legacy = root/'state.json'
    old = json.loads(legacy.read_text()) if legacy.exists() else {}
    result = ip_pool.new_pool(old.get('nonce'))
    if old.get('ids') and ip_pool.public_ipv4(old.get('host')):
        result['addresses'][old['host']] = {
            'mode': 'active', 'locked': False, 'missing_count': 0,
            'legacy_ids': old['ids'], 'legacy': True, 'egress': 'unknown', 'present': None}
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description='公网 IP 池：扫描、状态与操作计划（尚不自动修改面板）')
    parser.add_argument('action', choices=['status','scan','enable','disable','replace','lock','unlock','pause','resume','history','install-watch','stop-watch'])
    parser.add_argument('ip', nargs='?')
    parser.add_argument('target', nargs='?')
    parser.add_argument('--interface', action='append', help='限制扫描网卡，可重复传入')
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        raise RuntimeError('请以 root 运行')
    os.umask(0o077)
    if args.action in ('status', 'history'):
        # Read-only inspection does not create a pool or acquire a write lock.
        data = load(ROOT)
        print(json.dumps(data['history'] if args.action == 'history' else data,ensure_ascii=False,indent=2))
        return
    if args.action in ('enable','disable','replace','lock','unlock') and not args.ip:
        parser.error('该操作需要指定 IP')
    if args.action=='replace' and not args.target:
        parser.error('replace 需要旧 IP 和新 IP')
    with locked(ROOT):
        if args.action=='install-watch':
            install_watch()
            print('开机与定时发现已启用；此版本仅保存操作计划，不自动发布或更换节点。')
            return
        if args.action=='stop-watch':
            subprocess.run(['systemctl','disable','--now','whalenode-ip-pool.timer'],check=True,timeout=30)
            print('后续定时检查已停用；当前操作仍受统一锁保护。')
            return
        data = load(ROOT)
        if args.action == 'scan':
            found = ip_pool.scan(args.interface)
            if len(found)>32:
                raise RuntimeError('发现超过 32 个公网地址，请按网卡缩小检查范围')
            results={}
            for ip in found:
                try:results[ip]=ip_pool.verify_egress(ip)
                except (TimeoutError, ip_pool.subprocess.TimeoutExpired):
                    results[ip]={'status':'unknown'}
            boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip()
            uptime=float(Path('/proc/uptime').read_text().split()[0])
            data=ip_pool.reconcile(data,found,results,time.time(),boot,uptime)
        else:
            ip_pool.manual(data,args.action,args.ip,args.target)
        atomic(ROOT/'ip-pool.json',json.dumps(data,ensure_ascii=False,indent=2))
        print(json.dumps({'saved':True,'applied':False,'pool':data},ensure_ascii=False,indent=2))


if __name__=='__main__':
    try:main()
    except (Exception,KeyboardInterrupt) as error:
        print(str(error) if isinstance(error,(ValueError,RuntimeError)) else type(error).__name__,file=sys.stderr)
        sys.exit(1)
