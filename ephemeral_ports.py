"""Maximize non-privileged source ports without consuming service/hopping ports.

No service restart, dependency install, TCP timeout or durability changes.
The same implementation is used by node_build and scoped online maintenance.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import tempfile

LOW, HIGH = 1024, 65535
PERSIST = '/etc/sysctl.d/zz-whale-ephemeral.conf'
ROLLBACK = r'''from pathlib import Path
import json, hashlib, fcntl, os, tempfile
root=Path(__file__).resolve().parent
with open('/run/lock/whale-ephemeral.lock','a') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 m=json.loads((root/'receipt.json').read_text())
 base=Path('/proc/sys/net/ipv4');p=Path(m['persistent_path'])
 assert (base/'ip_local_port_range').read_text().split()==m['new_range'].split(),'Range changed; review rollback'
 assert (base/'ip_local_reserved_ports').read_text().strip()==m['new_reserved'],'Reservations changed; review rollback'
 assert hashlib.sha256(p.read_bytes()).hexdigest()==m['persistent_sha256'],'Persistent file changed; review rollback'
 old=root/'persistent.before'
 if old.exists():
  fd,name=tempfile.mkstemp(prefix='.whale-port-rollback-',dir=str(p.parent))
  with os.fdopen(fd,'wb') as f:f.write(old.read_bytes());f.flush();os.fsync(f.fileno())
  os.chmod(name,0o644);os.replace(name,p)
 else:p.unlink()
 (base/'ip_local_port_range').write_text(m['old_range']+'\n')
 (base/'ip_local_reserved_ports').write_text(m['old_reserved']+'\n')
 print('Restored only this port-pool change; no services restarted')
'''


def expand(value):
    ports = set()
    for part in str(value).split(','):
        if not part.strip():
            continue
        ends = [int(n) for n in part.strip().split('-')]
        if len(ends) > 2 or not 1 <= ends[0] <= ends[-1] <= HIGH:
            raise ValueError('Invalid reserved port range')
        ports.update(range(ends[0], ends[-1] + 1))
    return ports


def compact(ports):
    spans = []
    for n in sorted(ports):
        if spans and n == spans[-1][1] + 1:
            spans[-1][1] = n
        else:
            spans.append([n, n])
    return ','.join(str(a) if a == b else '%d-%d' % (a, b) for a, b in spans)


def listener_ports(output, old_range):
    """ss UDP UNCONN includes outbound sockets: never reserve the entire pool.

    TCP LISTEN, specifically bound UDP and wildcard UDP outside the old ephemeral
    range are service candidates. In-range wildcard services must be provided by
    the deployment plan (or existing reservations), e.g. HY2 on port 24443.
    """
    ports = set()
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 5 or fields[0] not in ('tcp', 'udp'):
            continue
        address, port = fields[4].rsplit(':', 1)
        if port.isdigit() and (fields[0] == 'tcp' or
                              address not in ('*', '0.0.0.0', '[::]', '::') or
                              not old_range[0] <= int(port) <= old_range[1]):
            ports.add(int(port))
    return ports


def atomic_write(path, raw):
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, 0o644)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def configure(extra_reserved='', apply=False):
    import fcntl  # Remote Linux only; source generation also runs on Windows.
    if os.geteuid() != 0:
        raise PermissionError('Requires existing root or noninteractive sudo')
    with open('/run/lock/whale-ephemeral.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        base = Path('/proc/sys/net/ipv4')
        range_path = base / 'ip_local_port_range'
        reserved_path = base / 'ip_local_reserved_ports'
        old_range = range_path.read_text().strip()
        old_reserved = reserved_path.read_text().strip()
        low, high = map(int, old_range.split())
        boundary = base / 'ip_unprivileged_port_start'
        # Older Linux kernels predate this setting and use the fixed 1024 boundary.
        privileged = int(boundary.read_text()) if boundary.exists() else 1024
        if privileged > LOW:
            raise ValueError('Nonstandard privileged-port boundary; review before expanding')
        listeners = subprocess.check_output(['ss', '-H', '-lntu'], text=True, timeout=20)
        reserved = expand(old_reserved) | expand(extra_reserved) | listener_ports(listeners, (low, high))
        new_reserved = compact(reserved)
        capacity = HIGH - LOW + 1 - sum(LOW <= n <= HIGH for n in reserved)
        if capacity < 16384:
            raise ValueError('Reserved ports leave insufficient capacity; review plan')
        body = ('# Managed by Whale ephemeral_ports.py; preserve service and hopping reservations.\n'
                'net.ipv4.ip_local_reserved_ports = ' + new_reserved + '\n'
                'net.ipv4.ip_local_port_range = %d %d\n' % (LOW, HIGH)).encode()
        path = Path(PERSIST)
        previous = path.read_bytes() if path.exists() else None
        result = {'old_range': old_range, 'new_range': '%d %d' % (LOW, HIGH),
                  'old_reserved': old_reserved, 'new_reserved': new_reserved,
                  'capacity': capacity, 'applied': False, 'persistent_path': PERSIST,
                  'persistent_sha256': hashlib.sha256(body).hexdigest()}
        if not apply:
            return result
        backup = Path(tempfile.mkdtemp(prefix='whale-ephemeral-max-', dir='/root'))
        os.chmod(backup, 0o700)
        if previous is not None:
            (backup / 'persistent.before').write_bytes(previous)
        result['backup'] = str(backup)
        (backup / 'before.json').write_text(json.dumps(result, indent=2))
        try:
            # Reserve before expansion so services never enter automatic allocation.
            reserved_path.write_text(new_reserved + '\n')
            range_path.write_text(result['new_range'] + '\n')
            atomic_write(path, body)
            assert range_path.read_text().split() == [str(LOW), str(HIGH)]
            assert expand(reserved_path.read_text()) == reserved
            assert path.read_bytes() == body
            result['applied'] = True
            (backup / 'receipt.json').write_text(json.dumps(result, indent=2))
            (backup / 'rollback.py').write_text(ROLLBACK)
            (backup / 'rollback.py').chmod(0o700)
            return result
        except Exception:
            # Restore only our exact writes; never overwrite concurrent external edits.
            if range_path.read_text().split() == [str(LOW), str(HIGH)]:
                range_path.write_text(old_range + '\n')
            if reserved_path.read_text().strip() == new_reserved:
                reserved_path.write_text(old_reserved + '\n')
            if path.exists() and path.read_bytes() == body:
                if previous is None:
                    path.unlink()
                else:
                    atomic_write(path, previous)
            raise


def remote_script(extra_reserved='', apply=True):
    # No credentials or target data are embedded beyond explicit reserved ports.
    return (Path(__file__).read_text(encoding='utf-8') +
            '\nprint(json.dumps(configure(%r, apply=%r)))\n' % (extra_reserved, apply))
