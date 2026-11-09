"""Public IPv4 discovery and durable intent planning; no panel mutations here."""
import copy
import ipaddress
import json
import subprocess
import time
import uuid

# Deliberately stable across Python versions. Conservatively exclude special-use
# space, including protocol assignments and deprecated transition mechanisms.
EXCLUDED = tuple(ipaddress.ip_network(x) for x in (
    '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
    '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24',
    '192.88.99.0/24', '192.168.0.0/16', '198.18.0.0/15',
    '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4', '240.0.0.0/4'))
ECHO_URLS = ('https://api.ipify.org', 'https://checkip.amazonaws.com')
VIRTUAL_KINDS = {'bridge', 'veth', 'tun', 'tap', 'wireguard', 'vxlan', 'gre', 'gretap', 'dummy'}


def public_ipv4(value):
    try:
        address = ipaddress.IPv4Address(value)
    except (ValueError, TypeError):
        return False
    return not any(address in network for network in EXCLUDED)


def addresses(document, interfaces=None):
    if not isinstance(document, list):
        raise ValueError('网卡扫描结果格式错误，不执行缺失判断')
    result = {}
    for link in document:
        name = link['ifname']
        if interfaces is not None and name not in interfaces:
            continue
        kind = link.get('linkinfo', {}).get('info_kind')
        if kind in VIRTUAL_KINDS or link.get('link_type') == 'loopback':
            continue
        if 'UP' not in link.get('flags', []):
            continue
        for item in link.get('addr_info', []):
            ip = item.get('local')
            if item.get('family') != 'inet' or item.get('scope') != 'global' or not public_ipv4(ip):
                continue
            flags = set(item.get('flags', []))
            if flags & {'tentative', 'dadfailed', 'deprecated'} or any(item.get(k) for k in ('tentative', 'dadfailed', 'deprecated')):
                continue
            if item.get('valid_life_time') == 0 or item.get('preferred_life_time') == 0:
                continue
            if ip in result and result[ip] != name:
                raise ValueError('公网地址出现在多个网卡，需先消除歧义')
            result[ip] = name
    return result


def scan(interfaces=None):
    proc = subprocess.run(['ip', '-j', '-d', '-4', 'addr', 'show'], capture_output=True, text=True, timeout=15)
    if proc.returncode:
        raise RuntimeError('网卡扫描失败，保留原状态')
    return addresses(json.loads(proc.stdout), interfaces)


def verify_egress(ip):
    if not public_ipv4(ip):
        raise ValueError('仅允许公网 IPv4')
    observations = []
    for url in ECHO_URLS:
        # Disable inherited proxy settings and curlrc; bind each source explicitly.
        proc = subprocess.run(['curl', '-q', '-4', '--silent', '--show-error', '--fail',
                               '--noproxy', '*', '--proto', '=https', '--max-time', '8',
                               '--max-filesize', '128', '--interface', ip, url],
                              capture_output=True, text=True, timeout=12)
        value = proc.stdout.strip()
        observations.append(value if proc.returncode == 0 and public_ipv4(value) else None)
    if all(value == ip for value in observations):
        status = 'verified'
    elif any(value is not None and value != ip for value in observations):
        status = 'mismatch'
    else:
        status = 'unknown'
    return {'status': status, 'observations': observations}


def new_pool(server_id=None):
    return {'schema': 1, 'server_id': server_id or uuid.uuid4().hex,
            'paused': False, 'auto_expand': False, 'auto_replace': True,
            'addresses': {}, 'intents': [], 'history': [], 'last_scan': None}


def event(pool, action, now, **fields):
    pool['history'].append(dict(at=now, action=action, **fields))
    pool['history'] = pool['history'][-200:]


def reconcile(original, found, results, now=None, boot_id=None, uptime=3600):
    """Return new state. Missing counts advance only on spaced, successful scans.

    This plans durable intent; it never claims intent has been applied remotely.
    A separate executor must revalidate and acknowledge each action.
    """
    now = time.time() if now is None else now
    if not isinstance(found, dict) or any(not public_ipv4(ip) for ip in found):
        raise ValueError('无效地址扫描')
    pool = copy.deepcopy(original)
    if pool.get('schema') != 1:
        raise ValueError('不支持的地址池版本')
    previous = pool.get('last_scan')
    spaced = previous is None or now - previous >= 240
    new_boot = pool.get('boot_id') != boot_id
    if new_boot:
        for entry in pool['addresses'].values():
            entry['missing_count'] = 0
    for ip, interface in found.items():
        entry = pool['addresses'].setdefault(ip, {'mode': 'standby', 'locked': False, 'missing_count': 0})
        entry.update(interface=interface, present=True, missing_count=0, seen_at=now)
        result = results.get(ip, {'status': 'unknown'})
        if result.get('status') not in ('unknown','mismatch','verified'):
            raise ValueError('无效出口验证结果')
        entry['egress'] = result['status']
        entry['checked_at'] = now
    for ip, entry in pool['addresses'].items():
        if ip not in found:
            entry['present'] = False
            entry['egress'] = 'unknown'
            if spaced and not new_boot and uptime >= 180:
                entry['missing_count'] = entry.get('missing_count', 0) + 1
    pool.update(last_scan=max(now, previous or now), boot_id=boot_id)
    if not pool['paused']:
        pending_ips = {ip for intent in pool['intents'] if intent['status'] in ('pending','cleanup_required')
                       for ip in (intent.get('old'), intent.get('new')) if ip}
        for ip, entry in sorted(pool['addresses'].items()):
            if entry.get('locked') or ip in pending_ips or now < entry.get('cooldown_until', 0):
                continue
            if entry['mode'] == 'active' and entry.get('missing_count', 0) >= 2:
                candidates = [p for p, e in sorted(pool['addresses'].items())
                              if p not in pending_ips and eligible(e, now)]
                target = candidates[0] if candidates and pool['auto_replace'] else None
                intent = enqueue(pool, 'replace' if target else 'hide', ip, target, now, 'automatic')
                pending_ips.update(x for x in (intent['old'], intent['new']) if x)
            elif pool['auto_expand'] and eligible(entry, now):
                enqueue(pool, 'enable', None, ip, now, 'automatic')
                pending_ips.add(ip)
    return pool


def eligible(entry, now):
    return (entry['mode'] == 'standby' and not entry.get('locked') and entry.get('present')
            and entry.get('egress') == 'verified' and 0 <= now-entry.get('checked_at', 0) <= 300
            and now >= entry.get('cooldown_until', 0))


def enqueue(pool, action, old, new, now, actor):
    unfinished={'pending','cleanup_required'}
    if len([x for x in pool['intents'] if x['status'] in unfinished]) >= 64:
        raise RuntimeError('待处理操作过多，请先处理已有计划')
    pool['intents']=[x for x in pool['intents'] if x['status'] in unfinished]+[
        x for x in pool['intents'] if x['status'] not in unfinished][-100:]
    intent = {'id': uuid.uuid4().hex, 'action': action, 'old': old, 'new': new,
              'at': now, 'actor': actor, 'status': 'pending'}
    pool['intents'].append(intent)
    event(pool, 'planned', now, intent_id=intent['id'], operation=action, old=old, new=new)
    return intent


def cancel(intent):
    # A prepared transaction may own hidden rows or a running candidate service.
    # Preserve its journal for explicit cleanup rather than silently losing it.
    intent['status']='cleanup_required' if intent.get('completed') else 'cancelled'


def manual(pool, action, ip=None, target=None, now=None):
    now = time.time() if now is None else now
    if action in ('pause', 'resume'):
        pool['paused'] = action == 'pause'
        if action == 'pause':
            for item in pool['intents']:
                if item['status'] == 'pending' and item['actor'] == 'automatic':
                    cancel(item)
        event(pool, action, now)
        return
    if ip not in pool['addresses']:
        raise ValueError('IP 不在已发现地址池中')
    entry = pool['addresses'][ip]
    if action in ('lock', 'unlock'):
        entry['locked'] = action == 'lock'
        if action == 'lock':
            for item in pool['intents']:
                if item['status'] == 'pending' and ip in (item['old'], item['new']):
                    cancel(item)
        event(pool, action, now, ip=ip)
        return
    if entry.get('locked'):
        raise ValueError('先解除人工锁定')
    if action not in ('enable', 'disable', 'replace'):
        raise ValueError('未知操作')
    if action in ('enable', 'replace'):
        candidate = ip if action == 'enable' else target
        if candidate not in pool['addresses'] or not eligible(pool['addresses'][candidate], now):
            raise ValueError('目标必须是当前验证通过且未锁定的备用公网 IP')
    if action == 'replace' and entry['mode'] != 'active':
        raise ValueError('只可替换启用中的入口')
    touched = {ip, target} - {None}
    if any(item['status']=='cleanup_required' and touched.intersection({item['old'],item['new']})
           for item in pool['intents']):
        raise RuntimeError('关联操作尚需清理，请先完成恢复')
    if any(item['status']=='pending' and item.get('completed') and touched.intersection({item['old'],item['new']})
           for item in pool['intents']):
        raise RuntimeError('关联操作已开始执行，请先暂停并完成恢复')
    for item in pool['intents']:
        if item['status'] == 'pending' and touched.intersection({item['old'], item['new']}):
            cancel(item)
    enqueue(pool, action, ip if action != 'enable' else None,
            target if action == 'replace' else ip if action == 'enable' else None, now, 'manual')
