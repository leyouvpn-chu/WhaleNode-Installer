"""Server-local WhaleNode installer. Python standard library only."""
import argparse
import fcntl
import getpass
import gzip
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path('/var/lib/whalenode-installer')
CONF = Path('/etc/whalenode')
PROTOCOLS = {'vless': ('vless', 28443), 'hy2': ('hysteria', 24443), 'anytls': ('anytls', 30443)}

def run(*args, check=True):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and p.returncode:
        raise RuntimeError('Command failed: ' + args[0] + ' (details omitted to protect credentials)')
    return p

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError('HTTP redirect refused; use the final HTTPS endpoint')

def https(url):
    p = urllib.parse.urlsplit(url)
    if p.scheme != 'https' or not p.hostname or p.username or p.password or p.fragment:
        raise ValueError('A valid HTTPS URL without embedded credentials is required')
    return url.rstrip('/')

def request(url, token=None, data=None):
    headers = {'User-Agent': 'WhaleNode-Installer/1', 'Accept': 'application/json'}
    if token:
        headers['Authorization'] = token
    if data is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(https(url), data=None if data is None else json.dumps(data).encode(), headers=headers)
    try:
        with urllib.request.build_opener(NoRedirect()).open(req, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        raise RuntimeError('API request failed, HTTP ' + str(e.code)) from None
    except (urllib.error.URLError, ValueError):
        raise RuntimeError('API request failed or returned invalid JSON') from None

def atomic(path, text, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def resources():
    cpu = len(os.sched_getaffinity(0))
    mem = int(next(x.split()[1] for x in Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemTotal:'))) // 1024
    for path in ('/sys/fs/cgroup/memory.max', '/sys/fs/cgroup/memory/memory.limit_in_bytes'):
        if Path(path).is_file():
            value = Path(path).read_text().strip()
            if value.isdigit(): mem = min(mem, int(value) // 1048576)
    if Path('/sys/fs/cgroup/cpu.max').is_file():
        quota, period = Path('/sys/fs/cgroup/cpu.max').read_text().split()
        if quota != 'max': cpu = min(cpu, max(1, math.ceil(int(quota) / int(period))))
    else:
        q = Path('/sys/fs/cgroup/cpu/cpu.cfs_quota_us')
        p = Path('/sys/fs/cgroup/cpu/cpu.cfs_period_us')
        if q.is_file() and p.is_file() and int(q.read_text()) > 0:
            cpu = min(cpu, max(1, math.ceil(int(q.read_text()) / int(p.read_text()))))
    if mem < 768: raise RuntimeError('At least 768 MiB available memory is required')
    return {'cpus': cpu, 'memory_mib': mem, 'go_memory_mib': min(int(mem * .6), mem - 384),
            'socket_buffer': min(16777216, max(2097152, mem * 1024)),
            'interfaces': sorted(p.name for p in Path('/sys/class/net').iterdir() if p.name != 'lo')}

def parser():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('api-url','api-key','admin-url','admin-token','binary-url','binary-sha256','source-commit','host','name'):
        p.add_argument('--' + name)
    p.add_argument('--api-key-file', type=Path)
    p.add_argument('--admin-token-file', type=Path)
    p.add_argument('--protocols', default=None)
    p.add_argument('--group-ids')
    p.add_argument('--route-ids')
    p.add_argument('--sni', default=None, help='Tested TLS server name; required for a new task')
    p.add_argument('--status', action='store_true')
    p.add_argument('--plan', action='store_true')
    return p

def rows(response):
    data = response.get('data')
    if not isinstance(data, list): raise RuntimeError('Unsupported V2Board getNodes response')
    return data

def main(argv=None):
    args = parser().parse_args(argv)
    if os.geteuid() != 0: raise RuntimeError('Run as root')
    os.umask(0o077)
    if args.plan:
        selected = (args.protocols or 'vless,hy2').split(',')
        if any(p not in PROTOCOLS for p in selected): raise ValueError('Protocols: vless,hy2,anytls')
        print(json.dumps({'protocols': selected, 'resources': resources(), 'publication': 'hidden pending external protocol tests, product grouping and monitoring'}, indent=2))
        return
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = open(ROOT / 'lock', 'w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    state_path = ROOT / 'state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    if args.status:
        print(json.dumps({k: state.get(k) for k in ('host','name','protocols','ids','phase','resources')}, indent=2))
        return
    selected = list(dict.fromkeys((args.protocols or ','.join(state.get('protocols', ['vless','hy2']))).split(',')))
    if not selected or any(p not in PROTOCOLS for p in selected): raise ValueError('Protocols: vless,hy2,anytls')
    if state.get('protocols') and selected != state['protocols']: raise ValueError('Resume must preserve protocols')
    facts = resources()
    if args.plan:
        print(json.dumps({'protocols': selected, 'resources': facts, 'steps': ['verify artifact and provenance','create hidden panel nodes','write backend configuration','apply bounded tuning','block service IPv6 egress','start and check listeners'], 'publication': 'hidden until external protocol acceptance and product/monitoring integration'}, indent=2))
        return
    if state.get('phase') == 'installed':
        print('Already installed. Use --status. Configuration changes require a separate reviewed operation.')
        return
    for service in ('V2bX.service','whalenode.service'):
        if run('systemctl','is-active','--quiet',service,check=False).returncode == 0:
            raise RuntimeError('An existing backend is active; no automatic replacement')
    if not state and (CONF.exists() or Path('/etc/systemd/system/whalenode.service').exists()):
        raise RuntimeError('Existing WhaleNode files require manual inspection before installation')
    for name in ('api_url','admin_url','binary_url','binary_sha256','source_commit','host','name','sni'):
        value = getattr(args,name) or state.get(name)
        if value: state[name] = value
    for name in ('api_url','admin_url','binary_url'):
        if not state.get(name): raise ValueError('Missing --' + name.replace('_','-'))
        https(state[name])
    if not re.fullmatch('[a-fA-F0-9]{64}',state.get('binary_sha256','')): raise ValueError('Supply --binary-sha256 of decompressed executable')
    if not re.fullmatch('[a-f0-9]{40}',state.get('source_commit','')): raise ValueError('Supply full --source-commit')
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9.-]{1,251}[a-zA-Z0-9]',state.get('sni','')): raise ValueError('Supply --sni with a tested TLS hostname')
    if not state.get('host'):
        geo = request('https://ipwho.is/')
        if geo.get('success') is not True: raise RuntimeError('Location detection failed; supply --host and --name')
        state['host'] = str(ipaddress.IPv4Address(geo['ip']))
        state.setdefault('name', str(geo['country_code']) + ' ' + str(geo['city']) + ' ' + state['host'])
    state['host'] = str(ipaddress.IPv4Address(state['host']))
    if not state.get('name'):
        geo = request('https://ipwho.is/' + state['host'])
        if geo.get('success') is not True: raise RuntimeError('Location detection failed; supply --name')
        state['name'] = str(geo['country_code']) + ' ' + str(geo['city']) + ' ' + state['host']
    if len(state['name']) > 80 or any(ord(c)<32 for c in state['name']): raise ValueError('Invalid node name')
    def ids(value):
        out = [int(x) for x in value.split(',') if x]
        if any(x<1 for x in out): raise ValueError('IDs must be positive integers')
        return out
    groups = ids(args.group_ids) if args.group_ids is not None else state.get('groups',[1])
    routes = ids(args.route_ids) if args.route_ids is not None else state.get('routes',[])
    if not groups: raise ValueError('At least one panel group is required')
    if state.get('ids') and (groups != state.get('groups') or routes != state.get('routes')):
        raise ValueError('Resume must preserve panel permission groups and routes')
    state.update(groups=groups,routes=routes)
    def credential(value, path, prompt):
        return value or (path.read_text().strip() if path else getpass.getpass(prompt))
    api_key = credential(args.api_key,args.api_key_file,'Node API key (hidden): ')
    admin = credential(args.admin_token,args.admin_token_file,'Panel admin authorization (hidden; not saved): ')
    if not api_key or not admin: raise ValueError('Empty credentials')
    state.update(protocols=selected, resources=facts)
    state.setdefault('ids',{})
    state.setdefault('nonce',secrets.token_hex(6))
    def save(phase):
        state['phase'] = phase
        atomic(state_path,json.dumps(state,indent=2))
    save('preflight')
    # Reject foreign listeners before downloading/configuring anything.
    for proto in selected:
        sock = '-lun' if proto=='hy2' else '-ltn'
        if len(run('ss',sock,'sport = :'+str(PROTOCOLS[proto][1])).stdout.splitlines())>1:
            raise RuntimeError('Required port already occupied: '+proto)
    all_nodes = rows(request(state['admin_url']+'/server/manage/getNodes',admin))
    releases = Path('/opt/whalenode/releases'); releases.mkdir(parents=True,exist_ok=True)
    binary = releases / state['binary_sha256']
    if not binary.exists():
        with tempfile.TemporaryDirectory(dir=str(ROOT)) as temp:
            archive = Path(temp)/'release.gz'
            try:
                with urllib.request.build_opener(NoRedirect()).open(state['binary_url'],timeout=120) as source, archive.open('wb') as out:
                    shutil.copyfileobj(source,out)
            except (urllib.error.URLError,OSError): raise RuntimeError('Artifact download failed') from None
            candidate=Path(temp)/'whalenode'
            with gzip.open(archive,'rb') as source, candidate.open('wb') as out: shutil.copyfileobj(source,out)
            if hashlib.sha256(candidate.read_bytes()).hexdigest()!=state['binary_sha256']:
                raise RuntimeError('Artifact hash mismatch')
            candidate.chmod(0o755)
            info=json.loads(run(str(candidate),'version','--json').stdout)
            if info.get('product')!='WhaleNode' or info.get('commit')!=state['source_commit'][:12] or info.get('profile')!='sing-owned':
                raise RuntimeError('WhaleNode build provenance mismatch')
            shutil.copyfile(candidate,binary);binary.chmod(0o755)
    if hashlib.sha256(binary.read_bytes()).hexdigest()!=state['binary_sha256']: raise RuntimeError('Installed binary hash mismatch')
    for proto in selected:
        typ,port=PROTOCOLS[proto]
        name=state['name']+' · '+proto.upper()
        matches=[x for x in all_nodes if x.get('type')==typ and x.get('name')==name]
        if proto in state['ids']:
            matches=[x for x in all_nodes if x.get('type')==typ and int(x['id'])==state['ids'][proto]]
        elif matches and not all(state['nonce'] in (x.get('tags') or []) for x in matches):
            raise RuntimeError('A foreign node already has this name; refusing to adopt it')
        if not matches:
            payload={'name':name,'host':state['host'],'port':port,'server_port':port,'group_id':groups,'route_id':routes,'rate':1,'show':0,'tags':[state['nonce']]}
            if proto=='vless':payload.update(tls=2,network='tcp',flow='xtls-rprx-vision',tls_settings={'server_name':state['sni'],'server_port':'443'})
            else:
                payload.update(server_name=state['sni'],insecure=1)
                if proto=='hy2':payload.update(version=2,obfs='salamander',obfs_password=secrets.token_hex(16),up_mbps=0,down_mbps=0)
            # A timed-out write is never retried here; next run reconciles its persisted tag.
            result=request(state['admin_url']+'/server/'+typ+'/save',admin,payload)
            if result.get('data') is not True:raise RuntimeError('Panel did not acknowledge node creation')
            all_nodes=rows(request(state['admin_url']+'/server/manage/getNodes',admin))
            matches=[x for x in all_nodes if x.get('type')==typ and x.get('name')==name and state['nonce'] in (x.get('tags') or [])]
        if len(matches)!=1 or matches[0].get('host')!=state['host'] or int(matches[0].get('show',0))!=0:
            raise RuntimeError('Panel reconciliation failed; nodes remain hidden')
        state['ids'][proto]=int(matches[0]['id']);save('panel')
    del admin
    if run('id','-u','whalenode',check=False).returncode:
        run('useradd','--system','--home-dir',str(CONF),'--shell','/usr/sbin/nologin','whalenode')
    uid=int(run('id','-u','whalenode').stdout)
    CONF.mkdir(mode=0o700,parents=True,exist_ok=True)
    nodes=[]
    for proto in selected:
        typ='hysteria2' if proto=='hy2' else proto
        nodes.append({'Core':'sing','ApiHost':state['api_url'],'ApiKey':api_key,'NodeID':state['ids'][proto],'NodeType':typ,'Timeout':180,'ListenIP':'0.0.0.0','SendIP':'0.0.0.0','CertConfig':{'CertMode':'self','CertDomain':state['sni'],'CertFile':str(CONF/(proto+'.cer')),'KeyFile':str(CONF/(proto+'.key'))}})
    config={'Log':{'Level':'warn','Output':''},'Cores':[{'Type':'sing','Log':{'Level':'warn'},'OriginalPath':str(CONF/'sing_original.json')}],'Nodes':nodes}
    atomic(CONF/'config.json',json.dumps(config))
    atomic(CONF/'sing_original.json',json.dumps({'route':{'rules':[]}}))
    run('chown','-R','whalenode:whalenode',str(CONF));CONF.chmod(0o700)
    # Own only this table. IPv6 management and other services are unaffected.
    table='table inet whalenode_egress { chain output { type filter hook output priority 0; policy accept; meta skuid '+str(uid)+' meta nfproto ipv6 counter reject; } }\n'
    nft=Path('/etc/whalenode-egress.nft')
    exists=run('nft','list','table','inet','whalenode_egress',check=False).returncode==0
    if exists and not state.get('owns_egress'):
        raise RuntimeError('Foreign egress table requires inspection')
    atomic(nft,table)
    if not exists:
        run('nft','--check','-f',str(nft))
        state['owns_egress']=True;save('egress')
        run('nft','-f',str(nft))
    atomic('/etc/systemd/system/whalenode-egress.service','[Unit]\nBefore=whalenode.service\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/sbin/nft -f /etc/whalenode-egress.nft\n[Install]\nWantedBy=multi-user.target\n',0o644)
    # Conservative, resource-bounded settings; never rewrite driver IRQ or offload blindly.
    settings={'net.core.somaxconn':8192,'net.core.rmem_max':facts['socket_buffer'],'net.core.wmem_max':facts['socket_buffer'],'net.ipv4.tcp_mtu_probing':1}
    old=json.loads((ROOT/'sysctl-before.json').read_text()) if (ROOT/'sysctl-before.json').exists() else {}
    for k in settings:
        if k not in old: old[k]=run('sysctl','-n',k).stdout.strip()
    atomic(ROOT/'sysctl-before.json',json.dumps(old))
    run('modprobe','tcp_bbr',check=False)
    if 'bbr' in run('sysctl','-n','net.ipv4.tcp_available_congestion_control').stdout.split():
        for k,v in {'net.ipv4.tcp_congestion_control':'bbr','net.core.default_qdisc':'fq'}.items():
            if k not in old: old[k]=run('sysctl','-n',k).stdout.strip()
            settings[k]=v
    atomic(ROOT/'sysctl-before.json',json.dumps(old))
    atomic('/etc/sysctl.d/90-whalenode.conf',''.join(str(k)+'='+str(v)+'\n' for k,v in settings.items()),0o644)
    run('sysctl','-p','/etc/sysctl.d/90-whalenode.conf')
    unit='[Unit]\nDescription=WhaleNode\nAfter=network-online.target whalenode-egress.service\nRequires=whalenode-egress.service\nWants=network-online.target\n[Service]\nUser=whalenode\nGroup=whalenode\nWorkingDirectory='+str(CONF)+'\nUMask=0077\nEnvironment=GOMEMLIMIT='+str(facts['go_memory_mib'])+'MiB\nEnvironment=GOMAXPROCS='+str(facts['cpus'])+'\nExecStart='+str(binary)+' server -c '+str(CONF/'config.json')+'\nRestart=always\nRestartSec=5\nLimitNOFILE=262144\nNoNewPrivileges=true\nProtectHome=true\nProtectSystem=strict\nReadWritePaths='+str(CONF)+'\n[Install]\nWantedBy=multi-user.target\n'
    atomic('/etc/systemd/system/whalenode.service',unit,0o644)
    run('systemctl','daemon-reload')
    # Table already loaded; mark oneshot active without loading it a second time.
    run('nft','delete','table','inet','whalenode_egress')
    run('systemctl','enable','--now','whalenode-egress.service')
    save('starting')
    run('systemctl','enable','--now','whalenode.service')
    time.sleep(10)
    run('systemctl','is-active','--quiet','whalenode.service')
    missing=[]
    for proto in selected:
        sock='-lun' if proto=='hy2' else '-ltn'
        if len(run('ss',sock,'sport = :'+str(PROTOCOLS[proto][1])).stdout.splitlines())<2:missing.append(proto)
    if missing:raise RuntimeError('Backend listeners missing: '+','.join(missing))
    save('installed')
    print('Installed; panel nodes remain hidden. External TCP/UDP protocol tests, product grouping and monitoring acceptance are still required. Inbound firewall rules were not changed.')

if __name__=='__main__':
    try:main()
    except (Exception,KeyboardInterrupt) as e:
        # Do not emit exception URLs, request bodies, credentials or stack locals.
        print('Installation incomplete: '+(str(e) if isinstance(e,(RuntimeError,ValueError)) else type(e).__name__),file=sys.stderr)
        sys.exit(1)
