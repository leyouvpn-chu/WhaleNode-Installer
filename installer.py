"""WhaleNode 服务器本机安装器，仅依赖 Python 标准库。"""
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
        raise RuntimeError('命令执行失败：' + args[0] + '（为保护凭据，未输出命令详情）')
    return p

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError('拒绝 HTTP 重定向，请使用最终的 HTTPS 地址')

def https(url):
    p = urllib.parse.urlsplit(url)
    if p.scheme != 'https' or not p.hostname or p.username or p.password or p.fragment:
        raise ValueError('请提供有效 HTTPS 地址，地址中不能内嵌账号密码或片段')
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
        raise RuntimeError('API 请求失败，HTTP 状态码：' + str(e.code)) from None
    except (urllib.error.URLError, ValueError):
        raise RuntimeError('API 请求失败或返回内容不是有效 JSON') from None

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
    if mem < 768: raise RuntimeError('至少需要 768 MiB 可用内存配额')
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
    p.add_argument('--sni', default=None, help='已测试可用的 TLS 域名，新任务必填')
    p.add_argument('--status', action='store_true')
    p.add_argument('--plan', action='store_true')
    return p

def rows(response):
    data = response.get('data')
    if not isinstance(data, list): raise RuntimeError('V2Board getNodes 响应格式不兼容')
    return data

def main(argv=None):
    args = parser().parse_args(argv)
    if os.geteuid() != 0: raise RuntimeError('请使用 root 或 sudo 运行')
    os.umask(0o077)
    if args.plan:
        selected = (args.protocols or 'vless,hy2').split(',')
        if any(p not in PROTOCOLS for p in selected): raise ValueError('支持的协议：vless,hy2,anytls')
        print(json.dumps({'protocols': selected, 'resources': resources(), 'publication': '保持隐藏，等待公网协议测试、产品分组和监控验收'}, ensure_ascii=False, indent=2))
        return
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = open(ROOT / 'lock', 'w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    state_path = ROOT / 'state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    if args.status:
        print(json.dumps({k: state.get(k) for k in ('host','name','protocols','ids','phase','resources')}, ensure_ascii=False, indent=2))
        return
    selected = list(dict.fromkeys((args.protocols or ','.join(state.get('protocols', ['vless','hy2']))).split(',')))
    if not selected or any(p not in PROTOCOLS for p in selected): raise ValueError('支持的协议：vless,hy2,anytls')
    if state.get('protocols') and selected != state['protocols']: raise ValueError('续跑必须保留原有协议组合')
    facts = resources()
    if args.plan:
        print(json.dumps({'protocols': selected, 'resources': facts, 'steps': ['verify artifact and provenance','create hidden panel nodes','write backend configuration','apply bounded tuning','block service IPv6 egress','start and check listeners'], 'publication': 'hidden until external protocol acceptance and product/monitoring integration'}, ensure_ascii=False, indent=2))
        return
    if state.get('phase') == 'installed':
        print('本任务已经安装完成。使用 --status 查看状态；不会重复覆盖现有配置。')
        return
    for service in ('V2bX.service','whalenode.service'):
        if run('systemctl','is-active','--quiet',service,check=False).returncode == 0:
            raise RuntimeError('检测到已有后端正在运行，未自动替换')
    if not state and (CONF.exists() or Path('/etc/systemd/system/whalenode.service').exists()):
        raise RuntimeError('发现已有 WhaleNode 文件，请检查后再安装')
    for name in ('api_url','admin_url','binary_url','binary_sha256','source_commit','host','name','sni'):
        value = getattr(args,name) or state.get(name)
        if value: state[name] = value
    for name in ('api_url','admin_url','binary_url'):
        if not state.get(name): raise ValueError('缺少必填参数 --' + name.replace('_','-'))
        https(state[name])
    if not re.fullmatch('[a-fA-F0-9]{64}',state.get('binary_sha256','')): raise ValueError('请通过 --binary-sha256 提供解压后可执行文件的 SHA256')
    if not re.fullmatch('[a-f0-9]{40}',state.get('source_commit','')): raise ValueError('请通过 --source-commit 提供完整的 40 位源码提交号')
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9.-]{1,251}[a-zA-Z0-9]',state.get('sni','')): raise ValueError('请通过 --sni 提供已测试可用的 TLS 域名')
    if not state.get('host'):
        geo = request('https://ipwho.is/')
        if geo.get('success') is not True: raise RuntimeError('地区识别失败，请提供 --host 和 --name')
        state['host'] = str(ipaddress.IPv4Address(geo['ip']))
        state.setdefault('name', str(geo['country_code']) + ' ' + str(geo['city']) + ' ' + state['host'])
    state['host'] = str(ipaddress.IPv4Address(state['host']))
    if not state.get('name'):
        geo = request('https://ipwho.is/' + state['host'])
        if geo.get('success') is not True: raise RuntimeError('地区识别失败，请提供 --name')
        state['name'] = str(geo['country_code']) + ' ' + str(geo['city']) + ' ' + state['host']
    if len(state['name']) > 80 or any(ord(c)<32 for c in state['name']): raise ValueError('节点名称无效')
    def ids(value):
        out = [int(x) for x in value.split(',') if x]
        if any(x<1 for x in out): raise ValueError('ID 必须是正整数')
        return out
    groups = ids(args.group_ids) if args.group_ids is not None else state.get('groups',[1])
    routes = ids(args.route_ids) if args.route_ids is not None else state.get('routes',[])
    if not groups: raise ValueError('至少需要一个面板权限组')
    if state.get('ids') and (groups != state.get('groups') or routes != state.get('routes')):
        raise ValueError('续跑必须保留原面板权限组和路由组')
    state.update(groups=groups,routes=routes)
    def credential(value, path, prompt):
        return value or (path.read_text().strip() if path else getpass.getpass(prompt))
    api_key = credential(args.api_key,args.api_key_file,'请输入节点 API 密钥（隐藏输入）：')
    admin = credential(args.admin_token,args.admin_token_file,'请输入面板管理员授权值（隐藏输入，不保存）：')
    if not api_key or not admin: raise ValueError('凭据不能为空')
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
            raise RuntimeError('所需端口已被占用，协议：'+proto)
    all_nodes = rows(request(state['admin_url']+'/server/manage/getNodes',admin))
    releases = Path('/opt/whalenode/releases'); releases.mkdir(parents=True,exist_ok=True)
    binary = releases / state['binary_sha256']
    if not binary.exists():
        with tempfile.TemporaryDirectory(dir=str(ROOT)) as temp:
            archive = Path(temp)/'release.gz'
            try:
                with urllib.request.build_opener(NoRedirect()).open(state['binary_url'],timeout=120) as source, archive.open('wb') as out:
                    shutil.copyfileobj(source,out)
            except (urllib.error.URLError,OSError): raise RuntimeError('发布包下载失败') from None
            candidate=Path(temp)/'whalenode'
            with gzip.open(archive,'rb') as source, candidate.open('wb') as out: shutil.copyfileobj(source,out)
            if hashlib.sha256(candidate.read_bytes()).hexdigest()!=state['binary_sha256']:
                raise RuntimeError('发布包 SHA256 校验失败')
            candidate.chmod(0o755)
            info=json.loads(run(str(candidate),'version','--json').stdout)
            if info.get('product')!='WhaleNode' or info.get('commit')!=state['source_commit'][:12] or info.get('profile')!='sing-owned':
                raise RuntimeError('WhaleNode 产品或构建来源校验失败')
            shutil.copyfile(candidate,binary);binary.chmod(0o755)
    if hashlib.sha256(binary.read_bytes()).hexdigest()!=state['binary_sha256']: raise RuntimeError('已下载可执行文件的 SHA256 不匹配')
    for proto in selected:
        typ,port=PROTOCOLS[proto]
        name=state['name']+' · '+proto.upper()
        matches=[x for x in all_nodes if x.get('type')==typ and x.get('name')==name]
        if proto in state['ids']:
            matches=[x for x in all_nodes if x.get('type')==typ and int(x['id'])==state['ids'][proto]]
        elif matches and not all(state['nonce'] in (x.get('tags') or []) for x in matches):
            raise RuntimeError('已有非本任务节点使用此名称，未接管或覆盖')
        if not matches:
            payload={'name':name,'host':state['host'],'port':port,'server_port':port,'group_id':groups,'route_id':routes,'rate':1,'show':0,'tags':[state['nonce']]}
            if proto=='vless':payload.update(tls=2,network='tcp',flow='xtls-rprx-vision',tls_settings={'server_name':state['sni'],'server_port':'443'})
            else:
                payload.update(server_name=state['sni'],insecure=1)
                if proto=='hy2':payload.update(version=2,obfs='salamander',obfs_password=secrets.token_hex(16),up_mbps=0,down_mbps=0)
            # A timed-out write is never retried here; next run reconciles its persisted tag.
            result=request(state['admin_url']+'/server/'+typ+'/save',admin,payload)
            if result.get('data') is not True:raise RuntimeError('面板未确认节点创建成功')
            all_nodes=rows(request(state['admin_url']+'/server/manage/getNodes',admin))
            matches=[x for x in all_nodes if x.get('type')==typ and x.get('name')==name and state['nonce'] in (x.get('tags') or [])]
        if len(matches)!=1 or matches[0].get('host')!=state['host'] or int(matches[0].get('show',0))!=0:
            raise RuntimeError('面板节点核对失败，新建节点仍保持隐藏')
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
        raise RuntimeError('发现非本任务的出口规则表，请先检查')
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
    if missing:raise RuntimeError('后端监听未就绪，协议：'+','.join(missing))
    save('installed')
    print('本机安装完成，面板节点仍保持隐藏。还需完成公网 TCP/UDP 协议测试、产品分组及监控验收；请核实入站防火墙规则。')

if __name__=='__main__':
    try:main()
    except (Exception,KeyboardInterrupt) as e:
        # Do not emit exception URLs, request bodies, credentials or stack locals.
        print('安装未完成：'+(str(e) if isinstance(e,(RuntimeError,ValueError)) else type(e).__name__),file=sys.stderr)
        sys.exit(1)
