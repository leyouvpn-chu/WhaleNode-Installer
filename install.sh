#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
WhaleNode Linux 一键安装器（需 root、systemd，支持 x86_64/aarch64）

当前显示的是使用帮助，尚未安装或修改节点。

首次安装可直接不带参数运行，按中文向导填写；也可用以下参数跳过对应输入：
  --api-url 地址          节点连接后台的 HTTPS 地址
  --admin-url 地址        面板管理 API 前缀（包含 /api/v1/管理路径）
  --release-manifest 地址 发布清单，自动选择当前架构、下载地址和校验值
  --binary-url 地址       手动指定 gzip 发布包（与下面两项配套）
  --binary-sha256 校验值  解压后可执行文件的 SHA256
  --source-commit 提交号  发布包对应的完整 40 位源码提交号
  --sni 域名              可选；默认从未复用候选域名中测试选择

敏感参数（省略后隐藏输入，不在终端显示）：
  --api-key 密钥          节点 API 密钥
  --admin-token 凭据      面板管理员授权值，仅本次使用，不保存
  --api-key-file 文件     从本机文件读取节点密钥
  --admin-token-file 文件 从本机文件读取管理员凭据
  --download-token-file 文件 私有下载 Bearer 令牌文件（root 专属，不保存令牌）
  --download-token 令牌    私有下载 Bearer 令牌（不保存）
  --download-token-prompt 隐藏输入私有下载令牌（不保存）

可选参数：
  --protocols vless,hy2   协议多选，默认 VLESS+REALITY 与 HY2，另支持 anytls
  --name 名称            自定义名称；省略按地区自动生成
  --host IPv4            公网入口 IP；省略自动识别
  --group-ids 1           面板权限组 ID，逗号分隔
  --route-ids 5,11,12     面板路由组 ID，需核实后台实际配置
  --plan                 只查看资源与计划，不安装（需已有 Python 3.9+）
  --status               查看已保存的任务进度
  --check                只读检查服务、端口、配置权限及 IPv6 出口规则
  --report-file 文件      配合 --check 导出脱敏 JSON 报告（必须是新文件）
  --rollback             停止本任务服务，恢复本任务修改的系统参数
  --node-group 分组       网关节点分组，默认 legacy_all（Whale + 旧 Super 共用）
  --no-publish           安装后保持面板隐藏（默认直接显示）
  --hide / --show        面板隐藏 / 重新显示本机节点
  --uninstall [--yes]    隐藏并删除面板节点，卸载本机 WhaleNode 与监控
  --non-interactive      禁止询问，缺参数直接报错
  --help                 显示本帮助

注意：节点 API 密钥不等于管理员授权值，自动建节点需要两者。
安装后默认直接在面板显示，并自动安装 Zabbix 监控；源站每分钟自动对账，
完成调度登记、节点分组和 Grafana/Zabbix 清单。再次运行本脚本出现管理菜单：
本机自检 / 面板隐藏 / 重新显示 / 卸载。失败后用原命令续跑。
HELP
  exit 0
fi
[[ "$EUID" -eq 0 ]] || { echo '请使用 root 或 sudo 运行' >&2; exit 1; }
[[ -f /etc/os-release ]] || { echo '缺少 /etc/os-release，无法识别系统' >&2; exit 1; }
. /etc/os-release
case "$ID" in
 debian) [[ "${VERSION_ID%%.*}" -ge 11 ]] || { echo "需要 Debian 11 或更新版本" >&2; exit 1; } ;;
 ubuntu) [[ "${VERSION_ID%%.*}" -ge 22 ]] || { echo "需要 Ubuntu 22 或更新版本" >&2; exit 1; } ;;
 centos|rocky|almalinux|rhel) [[ "${VERSION_ID%%.*}" -ge 9 ]] || { echo '需要 RHEL 系列 9+，支持 CentOS Stream 9/10' >&2; exit 1; } ;;
 *) echo '支持 Debian 11+、Ubuntu 22+、CentOS Stream/Rocky/AlmaLinux/RHEL 9+' >&2; exit 1 ;;
esac
read_only=false
for arg in "$@"; do
  [[ "$arg" != "--plan" && "$arg" != "--status" && "$arg" != "--check" ]] || read_only=true
done
if ! command -v python3 >/dev/null || ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,9) else 1)' 2>/dev/null; then
  [[ "$read_only" == false ]] || { echo '只读操作需要已有 Python 3.9+' >&2; exit 1; }
  echo '正在准备 Python 运行环境…'
  if command -v apt-get >/dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 ca-certificates
  else
    dnf install -y python3 ca-certificates
  fi
fi
python3 -c 'import sys; assert sys.version_info >= (3,9), "需要 Python 3.9 或更新版本"'
exec python3 - "$@" <<'WHALE_INSTALLER_PY'
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
import socket
import ssl
import platform
import pwd
import stat
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
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
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
            raw=response.read(16*1024*1024+1)
            if len(raw)>16*1024*1024:raise RuntimeError('API 响应超过大小限制')
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        raise RuntimeError('API 请求失败，HTTP 状态码：' + str(e.code)) from None
    except (urllib.error.URLError, ValueError):
        raise RuntimeError('API 请求失败或返回内容不是有效 JSON') from None

def ipv4_request(url):
    """双栈机器默认走 IPv6，查到的是 IPv6 出口；入口必须是公网 IPv4，所以只用 IPv4 连接。"""
    original=socket.getaddrinfo
    def only_v4(host,port,family=0,*rest,**kw):
        return original(host,port,socket.AF_INET,*rest,**kw)
    socket.getaddrinfo=only_v4
    try:return request(url)
    except RuntimeError:raise RuntimeError('无法通过 IPv4 识别公网地址；本机需要公网 IPv4，或用 --host 指定') from None
    finally:socket.getaddrinfo=original

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

def bounded_copy(source,out,limit):
    total=0
    while True:
        block=source.read(1024*1024)
        if not block:return
        total+=len(block)
        if total>limit:raise RuntimeError('发布包超过允许大小，已停止下载或解压')
        out.write(block)

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
    p.add_argument('--sni', default=None, help='可选；指定已测试可用的 TLS 域名')
    mode=p.add_mutually_exclusive_group()
    mode.add_argument('--status', action='store_true')
    mode.add_argument('--check', action='store_true', help='只读检查运行文件、监听、配置权限及 IPv6 出口规则')
    p.add_argument('--report-file', type=Path, help='配合 --check 输出不含凭据的 JSON 验收报告')
    p.add_argument('--download-token-file', type=Path, help='私有下载 Bearer 令牌文件，仅本次使用')
    p.add_argument('--download-token', help='私有下载 Bearer 令牌（会进入命令历史；优先用文件或隐藏输入）')
    p.add_argument('--download-token-prompt', action='store_true', help='隐藏输入私有下载 Bearer 令牌')
    mode.add_argument('--plan', action='store_true')
    p.add_argument('--non-interactive', action='store_true', help='禁止交互，缺少参数时直接报错')
    p.add_argument('--release-manifest', help='HTTPS 发布清单，自动选择架构及校验值')
    mode.add_argument('--rollback', action='store_true', help='停止本任务服务并恢复本任务修改的系统参数；保留隐藏面板节点')
    mode.add_argument('--hide', action='store_true', help='面板隐藏本机节点（用户不再收到）')
    mode.add_argument('--show', action='store_true', help='面板重新显示本机节点')
    mode.add_argument('--uninstall', action='store_true', help='隐藏并删除面板节点，卸载本机服务和监控')
    p.add_argument('--yes', action='store_true', help='卸载时不再确认')
    p.add_argument('--publish', action=argparse.BooleanOptionalAction, default=None,
                   help='安装后直接在面板显示（默认开启；--no-publish 保持隐藏）')
    p.add_argument('--node-group', help='网关节点分组，默认 legacy_all')
    return p

def prompt(text, default='', required=False):
    try:
        with open('/dev/tty','r',encoding='utf-8') as reader, open('/dev/tty','w',encoding='utf-8',buffering=1) as tty:
            while True:
                tty.write(text+(' ['+default+']' if default else '')+': ')
                tty.flush()
                line=reader.readline()
                if not line: raise RuntimeError('终端输入已关闭')
                value=line.strip() or default
                if value or not required:return value
                tty.write('此项不能为空。\n')
    except OSError:
        raise RuntimeError('没有交互终端，请通过参数提供配置或使用 SSH 终端执行') from None

def origin(url):
    p=urllib.parse.urlsplit(https(url))
    return (p.scheme,p.hostname.lower(),p.port or 443)

def download_auth(args, url, allowed_origin):
    token=getattr(args,'_download_token',None)
    if not token:return None
    if origin(url)!=origin(allowed_origin):
        raise RuntimeError('私有制品下载地址与鉴权来源不同，拒绝转发下载令牌')
    return 'Bearer '+token

def prepare_download_auth(args):
    if sum(map(bool,(args.download_token,args.download_token_file,args.download_token_prompt)))>1:
        raise ValueError('下载令牌只能用一种方式提供')
    if args.download_token_prompt and args.non_interactive:
        raise ValueError('非交互模式请使用 --download-token-file')
    token=args.download_token
    if args.download_token_file:
        fd=os.open(args.download_token_file,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        with os.fdopen(fd) as f:
            mode=os.fstat(f.fileno())
            if not stat.S_ISREG(mode.st_mode) or mode.st_uid!=0 or mode.st_mode & 0o077:
                raise ValueError('下载令牌文件必须由 root 所有，且不可被组或其他用户读取')
            token=f.read(8193).strip()
    elif args.download_token_prompt:
        token=getpass.getpass('请输入私有下载令牌（隐藏输入，不保存）：')
    if token is not None and (not token or len(token)>8192 or any(ord(c)<33 or ord(c)>126 for c in token)):
        raise ValueError('下载令牌格式无效')
    args._download_token=token

def manifest(url, machine=None, token=None):
    machine=machine or platform.machine()
    arch={'x86_64':'amd64','aarch64':'arm64'}.get(machine)
    if not arch:raise ValueError('不支持的 CPU 架构：'+machine)
    doc=request(url,token) if token else request(url)
    entry=doc.get('architectures',{}).get(arch)
    if doc.get('schema')!=1 or not isinstance(entry,dict):raise ValueError('发布清单未提供当前架构：'+arch)
    https(entry.get('url',''))
    if not re.fullmatch('[a-f0-9]{64}',entry.get('sha256','')) or not re.fullmatch('[a-f0-9]{40}',entry.get('source_commit','')):
        raise ValueError('发布清单的校验值或源码提交号无效')
    out={'binary_url':entry['url'],'binary_sha256':entry['sha256'],'source_commit':entry['source_commit']}
    out.update(monitor_entry(doc))
    return out

def monitor_entry(doc):
    mon=doc.get('monitor')
    if not isinstance(mon,dict):return {}
    https(mon.get('url',''))
    if not re.fullmatch('[a-f0-9]{64}',mon.get('sha256','')):raise ValueError('发布清单的监控接入包校验值无效')
    return {'monitor_url':mon['url'],'monitor_sha256':mon['sha256']}

def wizard(args,state):
    interactive=not args.non_interactive
    for name,label in [('api_url','节点 API 的 HTTPS 地址'),('admin_url','面板管理 API 前缀（含 /api/v1/管理路径）')]:
        if not getattr(args,name) and not state.get(name):
            if not interactive:raise ValueError('缺少参数 --'+name.replace('_','-'))
            setattr(args,name,prompt(label,required=True))
    if not args.protocols and not state.get('protocols') and interactive:
        args.protocols=prompt('选择协议，逗号多选：vless / hy2 / anytls','vless,hy2')
    if args.name is None and not state.get('name') and interactive:
        args.name=prompt('节点名称（直接回车自动按地区命名）') or None
    if args.group_ids is None and not state.get('groups') and interactive:
        args.group_ids=prompt('面板权限组 ID，逗号分隔','1')
    if args.route_ids is None and 'routes' not in state and interactive:
        args.route_ids=prompt('面板路由组 ID（回车不指定）')
    release=args.release_manifest or state.get('release_manifest')
    if not release and not (args.binary_url or state.get('binary_url')):
        if not interactive:raise ValueError('缺少 --release-manifest 或 --binary-url')
        release=prompt('WhaleNode HTTPS 发布清单地址（自动选择版本和校验值）',required=True)
    if release:
        if state.get('release_manifest') and release!=state['release_manifest'] and state.get('ids'):
            raise ValueError('续跑不能更换已使用的发布清单')
        if not all(state.get(k) for k in ('binary_url','binary_sha256','source_commit')):
            auth=download_auth(args,release,release)
            state.update(manifest(release,token=auth) if auth else manifest(release))
        state['release_manifest']=release
    else:
        for name,label in [('binary_sha256','可执行文件 SHA256'),('source_commit','完整源码提交 SHA')]:
            if not getattr(args,name) and not state.get(name) and interactive:
                setattr(args,name,prompt(label,required=True))

def choose_sni(used,tls13=False):
    for host in ('www.php.net','www.oracle.com','www.microsoft.com','www.apple.com','www.cloudflare.com'):
        if host in used:continue
        try:
            with socket.create_connection((host,443),timeout=5) as sock:
                with ssl.create_default_context().wrap_socket(sock,server_hostname=host) as tls:
                    # REALITY 借用目标站握手，必须支持 TLS 1.3。
                    if tls.version() and (not tls13 or tls.version()=='TLSv1.3'):return host
        except OSError:continue
    raise RuntimeError('自动 SNI 测试没有通过，请通过 --sni 指定已验证域名')

def dependency_check():
    if not Path('/run/systemd/system').is_dir():raise RuntimeError('需要使用 systemd 的服务器')
    needed=('nft','ss','sysctl','modprobe','useradd','runuser')
    if all(shutil.which(x) for x in needed):return
    print('正在安装缺少的运行依赖…',flush=True)
    if shutil.which('apt-get'):
        run('apt-get','update','-qq')
        run('env','DEBIAN_FRONTEND=noninteractive','apt-get','install','-y','--no-install-recommends','nftables','iproute2','procps','kmod','passwd','util-linux','ca-certificates')
    elif shutil.which('dnf'):
        run('dnf','install','-y','nftables','iproute','procps-ng','kmod','shadow-utils','util-linux','ca-certificates')
    else:raise RuntimeError('无法安装依赖：未找到 apt-get 或 dnf')

def rollback(state):
    if not state.get('owns_service') and not state.get('owns_egress'):raise RuntimeError('本任务尚未修改服务或系统参数，无需回滚')
    run('systemctl','disable','--now','whalenode.service',check=False)
    run('systemctl','disable','--now','whalenode-egress.service',check=False)
    if state.get('owns_egress'):run('nft','delete','table','inet','whalenode_egress',check=False)
    path=ROOT/'sysctl-before.json'
    if path.exists():
        for key,value in json.loads(path.read_text()).items():run('sysctl','-w',key+'='+str(value))
    for path in ['/etc/systemd/system/whalenode.service','/etc/systemd/system/whalenode-egress.service','/etc/whalenode-egress.nft','/etc/sysctl.d/90-whalenode.conf']:
        Path(path).unlink(missing_ok=True)
    run('systemctl','daemon-reload')
    state['phase']='rolled_back';atomic(ROOT/'state.json',json.dumps(state,ensure_ascii=False,indent=2))
    print('已停止本任务服务、移除本任务规则并恢复系统参数。配置和隐藏面板节点保留，便于核查及续跑。')

def active(unit):
    return run('systemctl','is-active','--quiet',unit,check=False).returncode==0

def export_report(path,report):
    # Never overwrite config, another report or a symlink with a diagnostic report.
    raw=json.dumps(report,ensure_ascii=False,indent=2).encode('utf-8')
    try:fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    except FileExistsError:raise ValueError('报告文件已存在，请使用新的文件名；未覆盖已有内容') from None
    except OSError:raise RuntimeError('无法创建报告，请检查目标目录及写入权限') from None
    with os.fdopen(fd,'wb') as f:
        f.write(raw);f.flush();os.fsync(f.fileno())

def diagnose(state):
    checks=[]
    def check(key,label,fn):
        try:passed=bool(fn())
        except Exception:passed=False
        checks.append({'key':key,'label':label,'passed':passed})
    check('state','存在本机安装任务',lambda:bool(state.get('ids')))
    check('backend_active','WhaleNode 服务运行',lambda:active('whalenode.service'))
    def running_hash():
        pid=run('systemctl','show','whalenode.service','--property=MainPID','--value').stdout.strip()
        if not pid.isdigit() or int(pid)==0:return False
        return hashlib.sha256(Path('/proc/'+pid+'/exe').read_bytes()).hexdigest()==state.get('binary_sha256')
    check('running_hash','运行文件 SHA256 与已校验制品一致',running_hash)
    def service_user():
        return run('systemctl','show','whalenode.service','--property=User','--value').stdout.strip()=='whalenode'
    check('service_user','后端使用专用非 root 用户',service_user)
    def private_config():
        uid=pwd.getpwnam('whalenode').pw_uid
        files=[(CONF,0o700),(CONF/'config.json',0o600),(CONF/'sing_original.json',0o600)]
        return all(not p.is_symlink() and p.stat().st_uid==uid and stat.S_IMODE(p.stat().st_mode)==mode for p,mode in files)
    check('config_permissions','后端配置属主及私密权限正确',private_config)
    def config_binding():
        nodes=json.loads((CONF/'config.json').read_text()).get('Nodes',[])
        expected={('hysteria2' if p=='hy2' else p,int(n)) for p,n in state.get('ids',{}).items()}
        return bool(expected) and len(nodes)==len(expected) and {(n.get('NodeType'),n.get('NodeID')) for n in nodes}==expected and all(n.get('ApiHost')==state.get('api_url') and n.get('ApiKey') for n in nodes)
    check('config_binding','配置中的面板与节点 ID 对应当前任务',config_binding)
    check('egress_active','IPv6 出口规则服务运行',lambda:active('whalenode-egress.service'))
    def ipv6_rule():
        uid=pwd.getpwnam('whalenode').pw_uid
        document=json.loads(run('nft','-j','list','table','inet','whalenode_egress').stdout)
        entries=document.get('nftables',[])
        chains=[x['chain'] for x in entries if 'chain' in x]
        if not any(c.get('name')=='output' and c.get('hook')=='output' and c.get('type')=='filter' for c in chains):return False
        rules=[x['rule'] for x in entries if 'rule' in x and x['rule'].get('chain')=='output']
        # Require the first rule to be our UID + IPv6 reject; an earlier accept could bypass it.
        if not rules:return False
        expr=rules[0].get('expr',[])
        matches=[e['match'] for e in expr if 'match' in e]
        if len(matches)!=2 or any(not ('match' in e or 'counter' in e or 'reject' in e) for e in expr):return False
        def matches_meta(key,values):
            return any(m.get('op')=='==' and m.get('left')=={'meta':{'key':key}} and m.get('right') in values for m in matches)
        return matches_meta('skuid',(uid,str(uid),'whalenode')) and matches_meta('nfproto',('ipv6',10)) and any('reject' in e for e in expr)
    check('ipv6_rule','首条出口规则拒绝专用用户的 IPv6 流量',ipv6_rule)
    for proto in state.get('protocols',[]):
        if proto not in PROTOCOLS:
            check('protocol_unknown','任务中存在未知协议',lambda:False);continue
        sock='-lun' if proto=='hy2' else '-ltn'
        check('listen_'+proto,proto.upper()+' 协议端口已监听',lambda sock=sock,proto=proto:len(run('ss',sock,'sport = :'+str(PROTOCOLS[proto][1])).stdout.splitlines())>1)
    return {'schema':1,'generated_at':int(time.time()),'scope':'local_only','passed':bool(checks) and all(x['passed'] for x in checks),
            'node':{k:state.get(k) for k in ('host','name','protocols','ids','phase','resources','source_commit','binary_sha256')},
            'checks':checks,'external_tcp_udp':'not_verified','central_monitoring':'not_verified','publication':'not_verified'}

def verify_service(state):
    report=diagnose(state)
    failed=[item['label'] for item in report['checks'] if not item['passed']]
    if failed:raise RuntimeError('本机验收失败：'+'；'.join(failed))


def rows(response):
    data = response.get('data')
    if not isinstance(data, list): raise RuntimeError('V2Board getNodes 响应格式不兼容')
    return data

MARK='wn-installer'

def save_state(state,phase=None):
    if phase:state['phase']=phase
    atomic(ROOT/'state.json',json.dumps(state,indent=2))

def secret(args,value,path,label):
    if value:return value
    if path:return path.read_text().strip()
    if args.non_interactive:raise ValueError('非交互模式缺少密钥参数或凭据文件')
    return getpass.getpass(label)

def admin_token(args):
    token=secret(args,args.admin_token,args.admin_token_file,'请输入面板管理员授权值（隐藏输入，不保存）：')
    if not token:raise ValueError('面板管理员授权值不能为空')
    return token

def ours(state,admin):
    # (type,id) 才唯一：不同协议表的 ID 会重复。
    return {(x.get('type'),int(x['id'])):x for x in rows(request(state['admin_url']+'/server/manage/getNodes',admin))
            if state.get('nonce') in (x.get('tags') or [])}

def set_show(state,admin,value):
    for proto,nid in state.get('ids',{}).items():
        result=request(state['admin_url']+'/server/'+PROTOCOLS[proto][0]+'/update',admin,{'id':nid,'show':value})
        if result.get('data') is not True:raise RuntimeError('面板未确认显示状态修改：'+proto)
    current=ours(state,admin)
    for proto,nid in state.get('ids',{}).items():
        row=current.get((PROTOCOLS[proto][0],nid))
        if not row or int(row.get('show',0))!=value:raise RuntimeError('面板显示状态核对失败：'+proto)
    state['published']=bool(value);save_state(state)

def install_monitor(args,state):
    """Zabbix agent2（PSK 自动注册）+ fleet 采集脚本；接入包来自私有下载并校验哈希。"""
    if not state.get('monitor_url') and state.get('release_manifest'):
        auth=download_auth(args,state['release_manifest'],state['release_manifest'])
        state.update(monitor_entry(request(state['release_manifest'],auth)))
    if not state.get('monitor_url'):raise RuntimeError('发布清单没有提供监控接入包，无法自动接入 Zabbix/Grafana')
    name='AUTO-'+state['nonce'].upper()
    if 'owns_agent' not in state:
        state['owns_agent']=shutil.which('zabbix_agent2') is None;save_state(state)
    auth=download_auth(args,state['monitor_url'],state.get('release_manifest') or state['monitor_url'])
    req=urllib.request.Request(state['monitor_url'],headers={'Authorization':auth} if auth else {})
    try:
        with urllib.request.build_opener(NoRedirect()).open(req,timeout=60) as source:
            body=source.read(4*1024*1024+1)
    except (urllib.error.URLError,OSError):raise RuntimeError('监控接入包下载失败') from None
    if len(body)>4*1024*1024 or hashlib.sha256(body).hexdigest()!=state['monitor_sha256']:
        raise RuntimeError('监控接入包 SHA256 校验失败')
    print('正在安装 Zabbix 监控（'+name+'）…',flush=True)
    fd,path=tempfile.mkstemp(dir=str(ROOT),prefix='.monitor-')
    try:
        with os.fdopen(fd,'wb') as f:f.write(body)
        # 接入包含自动注册 PSK：不回显其输出，只取结果行。
        p=subprocess.run(['bash',path,name,'whale:landing:auto_'+state['nonce']],text=True,
                         stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=900)
    finally:
        os.unlink(path)
    if p.returncode or 'MONITOR_READY' not in p.stdout:
        hint=[x for x in p.stdout.splitlines() if x.startswith(('UNSUPPORTED_RELEASE','DOWNLOAD_FAILED','SHA_MISMATCH','RESULT','dpkg failed'))]
        raise RuntimeError('Zabbix 监控安装失败'+('：'+hint[-1][:160] if hint else '')+'；修复后重新运行原命令续跑')
    state['monitor']=name;save_state(state)

def wait_sync(state,admin,timeout=600):
    """源站对账（每分钟）完成 node_ops、节点分组、监控清单后会给面板行打 wn-synced。"""
    print('等待源站自动接入调度、节点分组和监控（通常 1–3 分钟）…',flush=True)
    deadline=time.time()+timeout;last=None
    while time.time()<deadline:
        current=ours(state,admin)
        tags=[t for row in current.values() for t in (row.get('tags') or [])]
        if current and all('wn-synced' in (row.get('tags') or []) for row in current.values()):
            print('源站接入完成：已登记调度、加入节点分组、监控已上线，用户订阅可以拿到这台节点。');return True
        errors=sorted({t[9:] for t in tags if t.startswith('wn-error:')})
        if errors and errors!=last:
            print('源站正在重试：'+'、'.join(errors)+'（会自动继续）',flush=True);last=errors
        time.sleep(15)
    print('源站 10 分钟内未确认接入完成。节点已在面板显示；源站会继续自动重试，可稍后用 --status 查看。')
    return False

def ssh_port():
    out=run('ss','-ltnpH',check=False).stdout
    for line in out.splitlines():
        if '"sshd"' in line:
            port=line.split()[3].rsplit(':',1)[-1]
            if port.isdigit():return int(port)
    return 22

def remove_monitor(state):
    if not state.get('monitor'):return
    run('systemctl','disable','--now','whale-conntrack-proto.timer',check=False)
    for path in ('/etc/systemd/system/whale-conntrack-proto.service','/etc/systemd/system/whale-conntrack-proto.timer',
                 '/usr/local/sbin/whale-conntrack-proto','/etc/zabbix/whale-stack.sh','/etc/zabbix/whale.psk',
                 '/etc/zabbix/zabbix_agent2.d/plugins.d/whale-inventory.conf'):
        Path(path).unlink(missing_ok=True)
    if state.get('owns_agent'):
        run('systemctl','disable','--now','zabbix-agent2',check=False)
        if shutil.which('apt-get'):run('env','DEBIAN_FRONTEND=noninteractive','apt-get','purge','-y','-qq','zabbix-agent2',check=False)
        elif shutil.which('dnf'):run('dnf','remove','-y','zabbix-agent2',check=False)
    else:
        run('systemctl','restart','zabbix-agent2',check=False)

def uninstall(args,state):
    if not state.get('ids') and not state.get('owns_service'):raise RuntimeError('本机没有安装器任务，无需卸载')
    if not args.yes:
        if args.non_interactive:raise ValueError('非交互卸载需要 --yes 确认')
        if prompt('将隐藏并删除面板节点、卸载 WhaleNode 和监控。输入 yes 确认')!='yes':
            print('已取消，未做任何修改。');return
    admin=admin_token(args) if state.get('ids') else None
    if admin and state.get('published'):
        set_show(state,admin,0);print('面板已隐藏。',flush=True)
    run('systemctl','disable','--now','whalenode.service',check=False)
    run('systemctl','disable','--now','whalenode-egress.service',check=False)
    if admin:
        # 先停本机后端再删面板行：仍在拉配置的后端遇到被删的 NodeID 会报错重启。
        current=ours(state,admin)
        for proto,nid in state['ids'].items():
            if (PROTOCOLS[proto][0],nid) in current:
                result=request(state['admin_url']+'/server/'+PROTOCOLS[proto][0]+'/drop',admin,{'id':nid})
                if result.get('data') is not True:raise RuntimeError('面板未确认删除节点：'+proto)
        if ours(state,admin):raise RuntimeError('面板仍有本任务节点，卸载停止；本机服务已停止，可重新运行续做')
        print('面板节点已删除；源站会在 1–2 分钟内自动删除监控和调度登记。',flush=True)
    if state.get('owns_egress'):run('nft','delete','table','inet','whalenode_egress',check=False)
    path=ROOT/'sysctl-before.json'
    if path.exists():
        for key,value in json.loads(path.read_text()).items():run('sysctl','-w',key+'='+str(value),check=False)
    for item in ['/etc/systemd/system/whalenode.service','/etc/systemd/system/whalenode-egress.service','/etc/whalenode-egress.nft','/etc/sysctl.d/90-whalenode.conf']:
        Path(item).unlink(missing_ok=True)
    remove_monitor(state)
    run('systemctl','daemon-reload',check=False)
    shutil.rmtree(str(CONF),ignore_errors=True)
    shutil.rmtree('/opt/whalenode',ignore_errors=True)
    run('userdel','whalenode',check=False)
    shutil.rmtree(str(ROOT),ignore_errors=True)
    print('卸载完成：WhaleNode、出口规则、系统参数、Zabbix 监控和面板节点均已移除。')

def summary(state):
    shown='面板显示中' if state.get('published') else '面板已隐藏'
    return '已安装 · '+shown+' · 节点 '+', '.join(p+'#'+str(n) for p,n in state.get('ids',{}).items())+(' · 监控 '+state['monitor'] if state.get('monitor') else '')

def manage(args,state):
    if args.uninstall:return uninstall(args,state)
    if args.hide or args.show:
        if not state.get('ids'):raise RuntimeError('本机没有已创建的面板节点')
        set_show(state,admin_token(args),1 if args.show else 0)
        print('面板已'+('显示' if args.show else '隐藏')+'：'+summary(state));return
    print(summary(state))
    choice=prompt('选择操作：1 本机自检  2 面板隐藏  3 面板重新显示  4 卸载  0 退出','0')
    if choice=='1':
        for item in diagnose(state)['checks']:print(('通过' if item['passed'] else '失败')+'：'+item['label'])
    elif choice in ('2','3'):
        set_show(state,admin_token(args),1 if choice=='3' else 0);print('完成：'+summary(state))
    elif choice=='4':uninstall(args,state)

def main(argv=None):
    args = parser().parse_args(argv)
    if os.geteuid() != 0: raise RuntimeError('请使用 root 或 sudo 运行')
    os.umask(0o077)
    if args.report_file and not args.check:raise ValueError('--report-file 必须与 --check 一起使用')
    if args.plan:
        selected = (args.protocols or 'vless,hy2').split(',')
        if any(p not in PROTOCOLS for p in selected): raise ValueError('支持的协议：vless,hy2,anytls')
        print(json.dumps({'protocols': selected, 'resources': resources(), 'publication': '默认安装后直接在面板显示，源站自动接入调度、节点分组和监控；--no-publish 保持隐藏'}, ensure_ascii=False, indent=2))
        return
    if args.status or args.check:
        if args.status and args.check:raise ValueError('--status 和 --check 只能选择一个')
        state_path=ROOT/'state.json'
        state=json.loads(state_path.read_text()) if state_path.exists() else {}
        if args.status:
            print(json.dumps({k:state.get(k) for k in ('host','name','protocols','ids','phase','published','monitor','node_group','resources')},ensure_ascii=False,indent=2))
            return
        report=diagnose(state)
        if args.report_file:
            export_report(args.report_file,report)
        for item in report['checks']:
            print(('通过' if item['passed'] else '失败')+'：'+item['label'])
        print('本机自检不代表公网 TCP/UDP 或集中监控验收通过。')
        if not report['passed']:raise RuntimeError('本机自检未通过，请按失败项目排查；未修改服务或配置')
        return
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = open(ROOT / 'lock', 'w')
    try:fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:raise RuntimeError('已有安装任务正在运行，请勿同时执行；等待当前任务结束后再续跑') from None
    state_path = ROOT / 'state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    if args.rollback:
        rollback(state);return
    if args.hide or args.show or args.uninstall:
        manage(args,state);return
    def wanted(value):
        return list(dict.fromkeys(x.strip().lower() for x in value.split(',') if x.strip()))
    added=[x for x in wanted(args.protocols) if x not in state.get('protocols',[])] if args.protocols and state.get('protocols') else []
    if added and state.get('phase') in ('installed','published'):
        # 追加协议：已有面板行保留，只为新增协议建行，重写配置、重启后端，再显示全部线路。
        print('追加协议：'+','.join(added)+'（已有 '+','.join(state['protocols'])+' 保留）',flush=True)
        state['publish']=state.get('publish',True) if args.publish is None else args.publish
        state['published']=False;save_state(state,'adding')
    elif state.get('phase') in ('installed','published'):
        if run('systemctl','is-active','--quiet','whalenode.service',check=False).returncode:
            raise RuntimeError('任务记录已安装，但服务没有运行；请检查 journalctl -u whalenode，再执行 --rollback 后续跑')
        verify_service(state)
        if args.publish is not None:state['publish']=args.publish
        if state.get('monitor') and (state.get('published') or not state.get('publish',True)):
            if args.non_interactive or not os.isatty(0) and not Path('/dev/tty').exists():
                print(summary(state));return
            try:manage(args,state)
            except RuntimeError as e:
                if '没有交互终端' not in str(e):raise
                print(summary(state))
            return
        prepare_download_auth(args)
        finish(args,state);return
    for service in ('V2bX.service','whalenode.service'):
        if service=='whalenode.service' and state.get('owns_service'):
            run('systemctl','stop',service,check=False)
            continue
        if run('systemctl','is-active','--quiet',service,check=False).returncode==0:
            if service=='whalenode.service' and state.get('owns_service'):
                run('systemctl','stop',service)
            else:raise RuntimeError('发现已有后端服务，未覆盖：'+service)
    if not state and any(Path(p).exists() for p in (str(CONF),'/etc/systemd/system/whalenode.service','/etc/systemd/system/whalenode-egress.service','/etc/sysctl.d/90-whalenode.conf','/etc/whalenode-egress.nft')):
        raise RuntimeError('发现已有 WhaleNode 文件，请检查后再安装')
    print('WhaleNode 中文安装向导。已有参数自动采用，密钥隐藏输入。',flush=True)
    prepare_download_auth(args)
    wizard(args,state)
    selected = wanted(args.protocols or ','.join(state.get('protocols', ['vless','hy2'])))
    if state.get('protocols') and set(state['protocols'])<=set(selected):
        selected=state['protocols']+[x for x in selected if x not in state['protocols']]
    if not selected or any(p not in PROTOCOLS for p in selected): raise ValueError('支持的协议：vless,hy2,anytls')
    if state.get('protocols') and selected[:len(state['protocols'])] != state['protocols']: raise ValueError('只能追加协议，不能去掉已有协议；去掉请先 --uninstall')
    facts = resources()
    for name in ('api_url','admin_url','binary_url','binary_sha256','source_commit','host','name','sni'):
        value = getattr(args,name) or state.get(name)
        if state.get('ids') and state.get(name) != value:
            raise ValueError('已创建节点的续跑不能更改 --'+name.replace('_','-'))
        if value: state[name] = value
    for name in ('api_url','admin_url','binary_url'):
        if not state.get(name): raise ValueError('缺少必填参数 --' + name.replace('_','-'))
        https(state[name])
    if not re.fullmatch('[a-fA-F0-9]{64}',state.get('binary_sha256','')): raise ValueError('请通过 --binary-sha256 提供解压后可执行文件的 SHA256')
    state['binary_sha256']=state['binary_sha256'].lower()
    if not re.fullmatch('[a-f0-9]{40}',state.get('source_commit','')): raise ValueError('请通过 --source-commit 提供完整的 40 位源码提交号')
    if state.get('sni') and not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9.-]{1,251}[a-zA-Z0-9]',state['sni']): raise ValueError('请通过 --sni 提供已测试可用的 TLS 域名')
    if not state.get('host'):
        geo = ipv4_request('https://ipwho.is/')
        if geo.get('success') is not True: raise RuntimeError('地区识别失败，请提供 --host 和 --name')
        state['host'] = str(ipaddress.IPv4Address(geo['ip']))
        state.setdefault('name', str(geo['country_code']) + ' ' + str(geo['city']) + ' ' + state['host'])
    state['host'] = str(ipaddress.IPv4Address(state['host']))
    if not state.get('name'):
        geo = ipv4_request('https://ipwho.is/' + state['host'])
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
    node_group=args.node_group or state.get('node_group') or 'legacy_all'
    if not re.fullmatch('[a-z0-9_]{1,48}',node_group):raise ValueError('网关节点分组格式无效')
    if state.get('ids') and node_group!=state.get('node_group',node_group):raise ValueError('续跑不能更改 --node-group')
    state['node_group']=node_group
    state['publish']=args.publish if args.publish is not None else state.get('publish',True)
    def credential(value, path, label):
        return secret(args,value,path,label)
    if not args.api_key and not args.api_key_file and (CONF/'config.json').exists():
        previous=json.loads((CONF/'config.json').read_text())
        nodes=previous.get('Nodes',[])
        if nodes and all(n.get('ApiHost')==state['api_url'] for n in nodes):args.api_key=nodes[0].get('ApiKey')
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
    dependency_check()
    # Reject foreign listeners before downloading/configuring anything.
    for proto in selected:
        sock = '-lun' if proto=='hy2' else '-ltn'
        if len(run('ss',sock,'sport = :'+str(PROTOCOLS[proto][1])).stdout.splitlines())>1:
            raise RuntimeError('所需端口已被占用，协议：'+proto)
    all_nodes = rows(request(state['admin_url']+'/server/manage/getNodes',admin))
    state.setdefault('snis',{})
    used={str(x.get('server_name','')) for x in all_nodes}
    for x in all_nodes:
        tls=x.get('tls_settings')
        if isinstance(tls,dict):used.add(tls.get('server_name',''))
    for proto in selected:
        if proto not in state['snis']:
            state['snis'][proto]=state.get('sni') or choose_sni(used,tls13=proto=='vless')
            used.add(state['snis'][proto]);save('preflight')
    print('后台连接通过；正在校验后端发布包…',flush=True)
    releases = Path('/opt/whalenode/releases'); releases.mkdir(parents=True,exist_ok=True)
    releases.parent.chmod(0o755);releases.chmod(0o755)
    binary = releases / state['binary_sha256']
    if not binary.exists():
        if shutil.disk_usage(str(ROOT)).free<512*1024*1024:raise RuntimeError('安装分区至少需要 512 MiB 可用空间')
        with tempfile.TemporaryDirectory(dir=str(ROOT)) as temp:
            archive = Path(temp)/'release.gz'
            try:
                auth=download_auth(args,state['binary_url'],state.get('release_manifest') or state['binary_url'])
                req=urllib.request.Request(state['binary_url'],headers={'Authorization':auth} if auth else {})
                with urllib.request.build_opener(NoRedirect()).open(req,timeout=120) as source, archive.open('wb') as out:
                    bounded_copy(source,out,128*1024*1024)
            except (urllib.error.URLError,OSError): raise RuntimeError('发布包下载失败') from None
            candidate=Path(temp)/'whalenode'
            with gzip.open(archive,'rb') as source, candidate.open('wb') as out:bounded_copy(source,out,256*1024*1024)
            if hashlib.sha256(candidate.read_bytes()).hexdigest()!=state['binary_sha256']:
                raise RuntimeError('发布包 SHA256 校验失败')
            candidate.chmod(0o755)
            info=json.loads(run(str(candidate),'version','--json').stdout)
            if info.get('product')!='WhaleNode' or info.get('commit')!=state['source_commit'][:12] or info.get('profile')!='sing-owned':
                raise RuntimeError('WhaleNode 产品或构建来源校验失败')
            fd,staged=tempfile.mkstemp(dir=str(releases),prefix='.candidate-')
            try:
                with os.fdopen(fd,'wb') as out, candidate.open('rb') as source:
                    shutil.copyfileobj(source,out);out.flush();os.fsync(out.fileno())
                os.chmod(staged,0o755);os.replace(staged,binary)
            finally:
                if os.path.exists(staged):os.unlink(staged)
    if hashlib.sha256(binary.read_bytes()).hexdigest()!=state['binary_sha256']: raise RuntimeError('已下载可执行文件的 SHA256 不匹配')
    for proto in selected:
        typ,port=PROTOCOLS[proto]
        name=state['name']+' · '+proto.upper()
        matches=[x for x in all_nodes if x.get('type')==typ and x.get('name')==name]
        if proto in state['ids']:
            matches=[x for x in all_nodes if x.get('type')==typ and int(x['id'])==state['ids'][proto]]
        # 任何协议表里重名都会让网关整份订阅 4008，所以跨表检查。
        elif any(x.get('name')==name and state['nonce'] not in (x.get('tags') or []) for x in all_nodes):
            raise RuntimeError('面板已有同名节点（任意协议），未接管或覆盖：'+name)
        if not matches:
            tags=[MARK,state['nonce'],'wn-group:'+state['node_group'],'wn-cpu:'+str(facts['cpus']),
                  'wn-ssh:'+str(ssh_port()),'wn-name:'+state['name']]
            payload={'name':name,'host':state['host'],'port':port,'server_port':port,'group_id':groups,'route_id':routes,'rate':1,'show':0,'tags':tags}
            if proto=='vless':payload.update(tls=2,network='tcp',flow='xtls-rprx-vision',encryption='none',tls_settings={'server_name':state['snis'][proto],'dest':state['snis'][proto],'server_port':'443','cert_mode':'none','allow_insecure':'0','reject_unknown_sni':'0'})
            else:
                payload.update(server_name=state['snis'][proto],insecure=1)
                if proto=='hy2':payload.update(version=2,obfs='salamander',obfs_password=secrets.token_hex(16),up_mbps=0,down_mbps=0)
            # A timed-out write is never retried here; next run reconciles its persisted tag.
            result=request(state['admin_url']+'/server/'+typ+'/save',admin,payload)
            if result.get('data') is not True:raise RuntimeError('面板未确认节点创建成功')
            all_nodes=rows(request(state['admin_url']+'/server/manage/getNodes',admin))
            matches=[x for x in all_nodes if x.get('type')==typ and x.get('name')==name and state['nonce'] in (x.get('tags') or [])]
        # 新建的行必须仍是隐藏；追加协议时，已发布的老行保持显示。
        if len(matches)!=1 or matches[0].get('host')!=state['host'] or (proto not in state['ids'] and int(matches[0].get('show',0))!=0) or state['nonce'] not in (matches[0].get('tags') or []):
            raise RuntimeError('面板节点核对失败，新建节点仍保持隐藏')
        if int(matches[0].get('server_port',0))!=port:raise RuntimeError('面板节点端口与任务不一致，停止续跑')
        state['ids'][proto]=int(matches[0]['id']);save('panel')
        print('面板节点已核对：'+proto+' #'+str(state['ids'][proto]),flush=True)
    if run('id','-u','whalenode',check=False).returncode:
        run('useradd','--system','--home-dir',str(CONF),'--shell','/usr/sbin/nologin','whalenode')
    uid=int(run('id','-u','whalenode').stdout)
    CONF.mkdir(mode=0o700,parents=True,exist_ok=True)
    nodes=[]
    for proto in selected:
        typ='hysteria2' if proto=='hy2' else proto
        nodes.append({'Core':'sing','ApiHost':state['api_url'],'ApiKey':api_key,'NodeID':state['ids'][proto],'NodeType':typ,'Timeout':180,'ListenIP':'0.0.0.0','SendIP':'0.0.0.0','CertConfig':{'CertMode':'self','CertDomain':state['snis'][proto],'CertFile':str(CONF/(proto+'.cer')),'KeyFile':str(CONF/(proto+'.key'))}})
    config={'Log':{'Level':'warn','Output':''},'Cores':[{'Type':'sing','Log':{'Level':'warn'},'OriginalPath':str(CONF/'sing_original.json')}],'Nodes':nodes}
    atomic(CONF/'config.json',json.dumps(config))
    atomic(CONF/'sing_original.json',json.dumps({'route':{'rules':[]}}))
    run('chown','-R','whalenode:whalenode',str(CONF));CONF.chmod(0o700)
    # Own only this table. IPv6 management and other services are unaffected.
    table='table inet whalenode_egress {\n chain output {\n  type filter hook output priority 0; policy accept;\n  meta skuid '+str(uid)+' meta nfproto ipv6 counter reject\n }\n}\n'
    nft=Path('/etc/whalenode-egress.nft')
    exists=run('nft','list','table','inet','whalenode_egress',check=False).returncode==0
    if exists and not state.get('owns_egress'):
        raise RuntimeError('发现非本任务的出口规则表，请先检查')
    atomic(nft,table)
    if not exists:
        run('nft','--check','-f',str(nft))
        state['owns_egress']=True;save('egress')
        run('nft','-f',str(nft))
    atomic('/etc/systemd/system/whalenode-egress.service','[Unit]\nBefore=whalenode.service\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/sbin/nft -f /etc/whalenode-egress.nft\nExecStop=/usr/sbin/nft delete table inet whalenode_egress\n[Install]\nWantedBy=multi-user.target\n',0o644)
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
    state['owns_service']=True;save('configured')
    run('systemctl','daemon-reload')
    # Table already loaded; mark oneshot active without loading it a second time.
    run('systemctl','stop','whalenode-egress.service',check=False)
    run('nft','delete','table','inet','whalenode_egress',check=False)
    run('systemctl','enable','--now','whalenode-egress.service')
    save('starting')
    run('systemctl','enable','--now','whalenode.service')
    missing=selected[:]
    for _ in range(36):
        missing=[]
        for proto in selected:
            sock='-lun' if proto=='hy2' else '-ltn'
            if len(run('ss',sock,'sport = :'+str(PROTOCOLS[proto][1])).stdout.splitlines())<2:missing.append(proto)
        if not missing:break
        time.sleep(5)
    if missing:
        run('systemctl','stop','whalenode.service',check=False)
        raise RuntimeError('后端监听未就绪，已停止失败服务，协议：'+','.join(missing)+'；使用 journalctl -u whalenode 检查后可原命令续跑')
    verify_service(state)
    save('installed')
    print('本机安装完成：'+', '.join(p+' 端口 '+str(PROTOCOLS[p][1])+('/udp' if p=='hy2' else '/tcp') for p in selected)+
          '（云安全组需放行这些端口）。',flush=True)
    finish(args,state,admin)

def finish(args,state,admin=None):
    """安装后的自动步骤：监控 → 面板显示 → 等源站接入调度/分组/监控。每步可续跑。"""
    if not state.get('monitor'):install_monitor(args,state)
    if not state.get('publish',True):
        print('已按 --no-publish 保持面板隐藏；需要上线时运行 --show。');return
    if not state.get('published'):
        admin=admin or admin_token(args)
        set_show(state,admin,1)
        save_state(state,'published')
        print('面板已显示：'+', '.join(p+'#'+str(n) for p,n in state['ids'].items()),flush=True)
    admin=admin or admin_token(args)
    wait_sync(state,admin)
    print('管理：再次运行本脚本可选择 面板隐藏 / 重新显示 / 卸载；或直接用 --hide、--show、--uninstall。')

if __name__=='__main__':
    try:main()
    except (Exception,KeyboardInterrupt) as e:
        # Do not emit exception URLs, request bodies, credentials or stack locals.
        print('操作未完成：'+(str(e) if isinstance(e,(RuntimeError,ValueError)) else type(e).__name__),file=sys.stderr)
        sys.exit(1)

WHALE_INSTALLER_PY
