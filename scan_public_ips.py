"""Standalone, read-only public IPv4 interface and source-egress scanner."""
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


def inspect_ip(ip):
    try:
        return verify_egress(ip)
    except (subprocess.TimeoutExpired, TimeoutError, OSError):
        return {'status':'unknown','observations':[None,None]}


def main(argv=None):
    import argparse
    import concurrent.futures
    import datetime
    import shutil
    parser=argparse.ArgumentParser(description='旧版/新版服务器通用：只读扫描网卡公网 IPv4，并绑定每个源地址验证出口。不会安装节点、改网络、写入 IP 池或重启服务。')
    parser.add_argument('--json',action='store_true',help='输出 JSON，方便脚本调用')
    parser.add_argument('--interface',action='append',help='仅检查指定网卡，可重复传入')
    parser.add_argument('--ip',action='append',help='仅检查指定的已绑定公网 IP，可重复传入')
    args=parser.parse_args(argv)
    missing=[tool for tool in ('ip','curl') if not shutil.which(tool)]
    if missing:
        raise RuntimeError('缺少命令：'+', '.join(missing)+'；Debian/Ubuntu 可运行 apt-get install -y iproute2 curl ca-certificates')
    found=scan(args.interface)
    if args.ip:
        requested=set(args.ip)
        if not requested.issubset(found):
            raise ValueError('指定地址不是所选网卡上已启用的公网 IPv4：'+', '.join(sorted(requested-set(found))))
        found={ip:interface for ip,interface in found.items() if ip in requested}
    if len(found)>64:
        raise ValueError('发现超过 64 个候选地址，请用 --interface 或 --ip 限定范围')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        results=list(executor.map(inspect_ip,found))
    rows=[dict(ip=ip,interface=interface,**result) for (ip,interface),result in zip(found.items(),results)]
    report={'schema':1,'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'read_only':True,'family':'ipv4','echo_sources':list(ECHO_URLS),'addresses':rows,
            'verified_count':sum(r['status']=='verified' for r in rows)}
    if args.json:
        print(json.dumps(report,ensure_ascii=False,indent=2))
    else:
        print('公网 IPv4 扫描（只读，不修改节点或网络）')
        print('IP                网卡          出口验证         检测站返回')
        labels={'verified':'通过','mismatch':'不一致/NAT','unknown':'未确认/超时'}
        for row in rows:
            values=', '.join(v or '无有效响应' for v in row['observations'])
            print('%-17s %-13s %-12s %s'%(row['ip'],row['interface'],labels[row['status']],values))
        if not rows:print('没有发现符合条件的网卡公网 IPv4。控制台已分配但未绑定到网卡的地址不会列出。')
        print('出口验证不代表外部用户能连接 VPN，也不会自动建节点或换 IP。')
    return 4 if not rows else 0 if all(r['status']=='verified' for r in rows) else 3


if __name__=='__main__':
    import sys
    try:sys.exit(main())
    except (Exception,KeyboardInterrupt) as error:
        print('扫描未完成：'+(str(error) if isinstance(error,(RuntimeError,ValueError)) else type(error).__name__),file=sys.stderr)
        sys.exit(2)
