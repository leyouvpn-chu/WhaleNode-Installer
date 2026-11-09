#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
export PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
WhaleNode Linux 一键安装器（需 root、systemd，支持 x86_64/aarch64）

当前显示的是使用帮助，尚未安装或修改节点。

不带参数运行进入统一中文数字菜单；带 --menu 可携带安装参数进入菜单。
原有自动化参数仍直接执行，不需要通过菜单。
  --api-url 地址          节点连接后台的 HTTPS 地址
  --admin-url 地址        面板管理 API 前缀（包含 /api/v1/管理路径）
  --release-manifest 地址 发布清单，自动选择当前架构、下载地址和校验值
  --binary-url 地址       手动指定 gzip 发布包（与下面两项配套）
  --binary-sha256 校验值  解压后可执行文件的 SHA256
  --source-commit 提交号  发布包对应的完整 40 位源码提交号
  --sni 域名              可选；优先未用域名，不足时按使用次数择少复用，均测试 TLS

敏感参数（省略后隐藏输入，不在终端显示）：
  --api-key 密钥          节点 API 密钥
  --admin-token 凭据      面板管理员授权值，仅本次使用，不保存
  --api-key-file 文件     从本机文件读取节点密钥
  --admin-token-file 文件 从本机文件读取管理员凭据
  --download-token-file 文件 私有下载 Bearer 令牌文件（root 专属，不保存令牌）
  --download-token 令牌    私有下载 Bearer 令牌（不保存）
  --download-token-prompt 隐藏输入私有下载令牌（不保存）

可选参数：
  --menu                 统一数字菜单：安装、状态、扫描、IP 管理、隐藏/恢复、诊断
  --protocols vless,hy2   协议多选，默认 VLESS+REALITY 与 HY2，另支持 anytls
  --name 名称            自定义名称；省略按地区自动生成
  --host IPv4            公网入口 IP；省略自动识别
  --group-ids 1           面板权限组 ID，逗号分隔
  --route-ids 5,11,12     面板路由组 ID，需核实后台实际配置
  --plan                 只查看资源与计划，不安装（需已有 Python 3.8+）
  --status               查看已保存的任务进度
  --check                只读检查服务、端口、配置权限及 IPv6 出口规则
  --report-file 文件      配合 --check 导出脱敏 JSON 报告（必须是新文件）
  --rollback             停止本任务服务，恢复本任务修改的系统参数
  --retune               升级 CPU/内存后执行：按当前配置重算后端 CPU/内存上限和内核参数，
                         修正网卡队列算法（上限变化时重启后端，断线几秒）
  --node-group 分组       网关节点分组，默认 legacy_all（Whale + 旧 Super 共用）
  --ip-pool status       公网 IP 池状态（开发版：操作仅生成计划）
  --ip-pool scan         绑定各源地址核验公网出口
  --ip-pool lock IP      锁定地址，自动任务不得修改
  --ip-pool install-watch 开机与每五分钟扫描；不自动发布
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
 ubuntu) [[ "${VERSION_ID%%.*}" -ge 20 ]] || { echo "需要 Ubuntu 20.04 或更新版本" >&2; exit 1; } ;;
 centos|rocky|almalinux|rhel) [[ "${VERSION_ID%%.*}" -ge 9 ]] || { echo '需要 RHEL 系列 9+，支持 CentOS Stream 9/10' >&2; exit 1; } ;;
 *) echo '支持 Debian 11+、Ubuntu 20.04+、CentOS Stream/Rocky/AlmaLinux/RHEL 9+' >&2; exit 1 ;;
esac
# Debian 11 security packages have moved to the official archive. Scope the
# source rewrite to this process tree; never rewrite the host's apt sources.
if [[ "$ID" == debian && "${VERSION_ID%%.*}" == 11 && -x /usr/bin/apt-get ]]; then
  whale_apt_tmp=$(mktemp -d /tmp/whalenode-apt.XXXXXXXX)
  trap 'rm -rf -- "$whale_apt_tmp"' EXIT
  mkdir -p "$whale_apt_tmp/bin" "$whale_apt_tmp/sources.list.d"
  touch "$whale_apt_tmp/sources.list"
  for source in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$source" ]] || continue
    if [[ "$source" == /etc/apt/sources.list ]]; then
      target="$whale_apt_tmp/sources.list"
    else
      target="$whale_apt_tmp/sources.list.d/${source##*/}"
    fi
    sed -e 's#://deb.debian.org/debian-security#://archive.debian.org/debian-security#g' \
        -e 's#://security.debian.org/debian-security#://archive.debian.org/debian-security#g' \
        "$source" > "$target"
  done
  cat > "$whale_apt_tmp/bin/apt-get" <<'APT_WRAPPER'
#!/bin/sh
echo 'Debian 11：本次安装临时使用官方安全更新归档，原软件源文件保持不变。' >&2
exec /usr/bin/apt-get -o "Dir::Etc::sourcelist=$WHALE_APT_SOURCES/sources.list" -o "Dir::Etc::sourceparts=$WHALE_APT_SOURCES/sources.list.d" "$@"
APT_WRAPPER
  chmod 0755 "$whale_apt_tmp/bin/apt-get"
  export WHALE_APT_SOURCES="$whale_apt_tmp"
  export PATH="$whale_apt_tmp/bin:$PATH"
fi
read_only=false
[[ "$#" -ne 0 ]] || read_only=true
for arg in "$@"; do
  [[ "$arg" != "--plan" && "$arg" != "--status" && "$arg" != "--check" && "$arg" != "--menu" && "$arg" != "--ip-pool" ]] || read_only=true
done
if ! command -v python3 >/dev/null || ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)' 2>/dev/null; then
  [[ "$read_only" == false ]] || { echo '菜单/只读操作需要已有 Python 3.8+；Debian/Ubuntu 请先运行 apt-get update && apt-get install -y python3 ca-certificates iproute2 curl' >&2; exit 1; }
  echo '正在准备 Python 运行环境…'
  if command -v apt-get >/dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 ca-certificates
  else
    dnf install -y python3 ca-certificates
  fi
fi
python3 -c 'import sys; assert sys.version_info >= (3,8), "需要 Python 3.8 或更新版本"'
python3 - "$@" <<'WHALE_INSTALLER_PY'
import sys,types
_ep=types.ModuleType("ephemeral_ports")
exec('"""Maximize non-privileged source ports without consuming service/hopping ports.\n\nNo service restart, dependency install, TCP timeout or durability changes.\nThe same implementation is used by node_build and scoped online maintenance.\n"""\nfrom pathlib import Path\nimport hashlib\nimport json\nimport os\nimport subprocess\nimport tempfile\n\nLOW, HIGH = 1024, 65535\nPERSIST = \'/etc/sysctl.d/zz-whale-ephemeral.conf\'\nROLLBACK = r\'\'\'from pathlib import Path\nimport json, hashlib, fcntl, os, tempfile\nroot=Path(__file__).resolve().parent\nwith open(\'/run/lock/whale-ephemeral.lock\',\'a\') as lock:\n fcntl.flock(lock,fcntl.LOCK_EX)\n m=json.loads((root/\'receipt.json\').read_text())\n base=Path(\'/proc/sys/net/ipv4\');p=Path(m[\'persistent_path\'])\n assert (base/\'ip_local_port_range\').read_text().split()==m[\'new_range\'].split(),\'Range changed; review rollback\'\n assert (base/\'ip_local_reserved_ports\').read_text().strip()==m[\'new_reserved\'],\'Reservations changed; review rollback\'\n assert hashlib.sha256(p.read_bytes()).hexdigest()==m[\'persistent_sha256\'],\'Persistent file changed; review rollback\'\n old=root/\'persistent.before\'\n if old.exists():\n  fd,name=tempfile.mkstemp(prefix=\'.whale-port-rollback-\',dir=str(p.parent))\n  with os.fdopen(fd,\'wb\') as f:f.write(old.read_bytes());f.flush();os.fsync(f.fileno())\n  os.chmod(name,0o644);os.replace(name,p)\n else:p.unlink()\n (base/\'ip_local_port_range\').write_text(m[\'old_range\']+\'\\n\')\n (base/\'ip_local_reserved_ports\').write_text(m[\'old_reserved\']+\'\\n\')\n print(\'Restored only this port-pool change; no services restarted\')\n\'\'\'\n\n\ndef expand(value):\n    ports = set()\n    for part in str(value).split(\',\'):\n        if not part.strip():\n            continue\n        ends = [int(n) for n in part.strip().split(\'-\')]\n        if len(ends) > 2 or not 1 <= ends[0] <= ends[-1] <= HIGH:\n            raise ValueError(\'Invalid reserved port range\')\n        ports.update(range(ends[0], ends[-1] + 1))\n    return ports\n\n\ndef compact(ports):\n    spans = []\n    for n in sorted(ports):\n        if spans and n == spans[-1][1] + 1:\n            spans[-1][1] = n\n        else:\n            spans.append([n, n])\n    return \',\'.join(str(a) if a == b else \'%d-%d\' % (a, b) for a, b in spans)\n\n\ndef listener_ports(output, old_range):\n    """ss UDP UNCONN includes outbound sockets: never reserve the entire pool.\n\n    TCP LISTEN, specifically bound UDP and wildcard UDP outside the old ephemeral\n    range are service candidates. In-range wildcard services must be provided by\n    the deployment plan (or existing reservations), e.g. HY2 on port 24443.\n    """\n    ports = set()\n    for line in output.splitlines():\n        fields = line.split()\n        if len(fields) < 5 or fields[0] not in (\'tcp\', \'udp\'):\n            continue\n        address, port = fields[4].rsplit(\':\', 1)\n        if port.isdigit() and (fields[0] == \'tcp\' or\n                              address not in (\'*\', \'0.0.0.0\', \'[::]\', \'::\') or\n                              not old_range[0] <= int(port) <= old_range[1]):\n            ports.add(int(port))\n    return ports\n\n\ndef atomic_write(path, raw):\n    path = Path(path)\n    fd, name = tempfile.mkstemp(prefix=\'.\' + path.name, dir=str(path.parent))\n    try:\n        with os.fdopen(fd, \'wb\') as handle:\n            handle.write(raw)\n            handle.flush()\n            os.fsync(handle.fileno())\n        os.chmod(name, 0o644)\n        os.replace(name, path)\n    finally:\n        if os.path.exists(name):\n            os.unlink(name)\n\n\ndef configure(extra_reserved=\'\', apply=False):\n    import fcntl  # Remote Linux only; source generation also runs on Windows.\n    if os.geteuid() != 0:\n        raise PermissionError(\'Requires existing root or noninteractive sudo\')\n    with open(\'/run/lock/whale-ephemeral.lock\', \'a\') as lock:\n        fcntl.flock(lock, fcntl.LOCK_EX)\n        base = Path(\'/proc/sys/net/ipv4\')\n        range_path = base / \'ip_local_port_range\'\n        reserved_path = base / \'ip_local_reserved_ports\'\n        old_range = range_path.read_text().strip()\n        old_reserved = reserved_path.read_text().strip()\n        low, high = map(int, old_range.split())\n        boundary = base / \'ip_unprivileged_port_start\'\n        # Older Linux kernels predate this setting and use the fixed 1024 boundary.\n        privileged = int(boundary.read_text()) if boundary.exists() else 1024\n        if privileged > LOW:\n            raise ValueError(\'Nonstandard privileged-port boundary; review before expanding\')\n        listeners = subprocess.check_output([\'ss\', \'-H\', \'-lntu\'], text=True, timeout=20)\n        reserved = expand(old_reserved) | expand(extra_reserved) | listener_ports(listeners, (low, high))\n        new_reserved = compact(reserved)\n        capacity = HIGH - LOW + 1 - sum(LOW <= n <= HIGH for n in reserved)\n        if capacity < 16384:\n            raise ValueError(\'Reserved ports leave insufficient capacity; review plan\')\n        body = (\'# Managed by Whale ephemeral_ports.py; preserve service and hopping reservations.\\n\'\n                \'net.ipv4.ip_local_reserved_ports = \' + new_reserved + \'\\n\'\n                \'net.ipv4.ip_local_port_range = %d %d\\n\' % (LOW, HIGH)).encode()\n        path = Path(PERSIST)\n        previous = path.read_bytes() if path.exists() else None\n        result = {\'old_range\': old_range, \'new_range\': \'%d %d\' % (LOW, HIGH),\n                  \'old_reserved\': old_reserved, \'new_reserved\': new_reserved,\n                  \'capacity\': capacity, \'applied\': False, \'persistent_path\': PERSIST,\n                  \'persistent_sha256\': hashlib.sha256(body).hexdigest()}\n        if not apply:\n            return result\n        backup = Path(tempfile.mkdtemp(prefix=\'whale-ephemeral-max-\', dir=\'/root\'))\n        os.chmod(backup, 0o700)\n        if previous is not None:\n            (backup / \'persistent.before\').write_bytes(previous)\n        result[\'backup\'] = str(backup)\n        (backup / \'before.json\').write_text(json.dumps(result, indent=2))\n        try:\n            # Reserve before expansion so services never enter automatic allocation.\n            reserved_path.write_text(new_reserved + \'\\n\')\n            range_path.write_text(result[\'new_range\'] + \'\\n\')\n            atomic_write(path, body)\n            assert range_path.read_text().split() == [str(LOW), str(HIGH)]\n            assert expand(reserved_path.read_text()) == reserved\n            assert path.read_bytes() == body\n            result[\'applied\'] = True\n            (backup / \'receipt.json\').write_text(json.dumps(result, indent=2))\n            (backup / \'rollback.py\').write_text(ROLLBACK)\n            (backup / \'rollback.py\').chmod(0o700)\n            return result\n        except Exception:\n            # Restore only our exact writes; never overwrite concurrent external edits.\n            if range_path.read_text().split() == [str(LOW), str(HIGH)]:\n                range_path.write_text(old_range + \'\\n\')\n            if reserved_path.read_text().strip() == new_reserved:\n                reserved_path.write_text(old_reserved + \'\\n\')\n            if path.exists() and path.read_bytes() == body:\n                if previous is None:\n                    path.unlink()\n                else:\n                    atomic_write(path, previous)\n            raise\n\n\ndef remote_script(extra_reserved=\'\', apply=True):\n    # No credentials or target data are embedded beyond explicit reserved ports.\n    return (Path(__file__).read_text(encoding=\'utf-8\') +\n            \'\\nprint(json.dumps(configure(%r, apply=%r)))\\n\' % (extra_reserved, apply))\n',_ep.__dict__)
sys.modules["ephemeral_ports"]=_ep
# Embedded IP management modules are unpacked only for the IP-pool command.
import sys as _sys
if not _sys.argv[1:] or '--menu' in _sys.argv[1:] or _sys.argv[1:2] == ['--ip-pool']:
    import tempfile as _tempfile, pathlib as _pathlib, base64 as _base64, atexit as _atexit
    _bundle = _tempfile.TemporaryDirectory(prefix='whalenode-ip-pool-')
    _atexit.register(_bundle.cleanup)
    for _name, _data in {'installer.py': 'IiIiV2hhbGVOb2RlIOacjeWKoeWZqOacrOacuuWuieijheWZqO+8jOS7heS+nei1liBQeXRob24g5qCH5YeG5bqT44CCIiIiCmltcG9ydCBhcmdwYXJzZQpmcm9tIGNvbGxlY3Rpb25zIGltcG9ydCBDb3VudGVyCmltcG9ydCBmY250bAppbXBvcnQgZ2V0cGFzcwppbXBvcnQgZ3ppcAppbXBvcnQgaGFzaGxpYgppbXBvcnQgaXBhZGRyZXNzCmltcG9ydCBqc29uCmltcG9ydCBtYXRoCmltcG9ydCBvcwpmcm9tIHBhdGhsaWIgaW1wb3J0IFBhdGgKaW1wb3J0IHJlCmltcG9ydCBzZWNyZXRzCmltcG9ydCBzaHV0aWwKaW1wb3J0IHNvY2tldAppbXBvcnQgc3NsCmltcG9ydCBwbGF0Zm9ybQppbXBvcnQgcHdkCmltcG9ydCBzdGF0CmltcG9ydCBzdWJwcm9jZXNzCmltcG9ydCBzeXMKaW1wb3J0IHRlbXBmaWxlCmltcG9ydCB0aW1lCmltcG9ydCB1cmxsaWIuZXJyb3IKaW1wb3J0IHVybGxpYi5wYXJzZQppbXBvcnQgdXJsbGliLnJlcXVlc3QKZnJvbSBlcGhlbWVyYWxfcG9ydHMgaW1wb3J0IGNvbmZpZ3VyZSBhcyBjb25maWd1cmVfZXBoZW1lcmFsX3BvcnRzCgpST09UID0gUGF0aCgnL3Zhci9saWIvd2hhbGVub2RlLWluc3RhbGxlcicpCkNPTkYgPSBQYXRoKCcvZXRjL3doYWxlbm9kZScpClVOSVQgPSBQYXRoKCcvZXRjL3N5c3RlbWQvc3lzdGVtL3doYWxlbm9kZS5zZXJ2aWNlJykKUFJPVE9DT0xTID0geyd2bGVzcyc6ICgndmxlc3MnLCAyODQ0MyksICdoeTInOiAoJ2h5c3RlcmlhJywgMjQ0NDMpLCAnYW55dGxzJzogKCdhbnl0bHMnLCAzMDQ0Myl9CgpkZWYgcnVuKCphcmdzLCBjaGVjaz1UcnVlKToKICAgIHAgPSBzdWJwcm9jZXNzLnJ1bihhcmdzLCB0ZXh0PVRydWUsIHN0ZG91dD1zdWJwcm9jZXNzLlBJUEUsIHN0ZGVycj1zdWJwcm9jZXNzLlBJUEUsIHRpbWVvdXQ9NjAwKQogICAgaWYgY2hlY2sgYW5kIHAucmV0dXJuY29kZToKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+WRveS7pOaJp+ihjOWksei0pe+8micgKyBhcmdzWzBdICsgJ++8iOS4uuS/neaKpOWHreaNru+8jOacqui+k+WHuuWRveS7pOivpuaDhe+8iScpCiAgICByZXR1cm4gcAoKY2xhc3MgTm9SZWRpcmVjdCh1cmxsaWIucmVxdWVzdC5IVFRQUmVkaXJlY3RIYW5kbGVyKToKICAgIGRlZiByZWRpcmVjdF9yZXF1ZXN0KHNlbGYsIHJlcSwgZnAsIGNvZGUsIG1zZywgaGVhZGVycywgbmV3dXJsKToKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+aLkue7nSBIVFRQIOmHjeWumuWQke+8jOivt+S9v+eUqOacgOe7iOeahCBIVFRQUyDlnLDlnYAnKQoKZGVmIGh0dHBzKHVybCk6CiAgICBwID0gdXJsbGliLnBhcnNlLnVybHNwbGl0KHVybCkKICAgIGlmIHAuc2NoZW1lICE9ICdodHRwcycgb3Igbm90IHAuaG9zdG5hbWUgb3IgcC51c2VybmFtZSBvciBwLnBhc3N3b3JkIG9yIHAuZnJhZ21lbnQ6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcign6K+35o+Q5L6b5pyJ5pWIIEhUVFBTIOWcsOWdgO+8jOWcsOWdgOS4reS4jeiDveWGheW1jOi0puWPt+WvhueggeaIlueJh+autScpCiAgICByZXR1cm4gdXJsLnJzdHJpcCgnLycpCgpkZWYgcmVxdWVzdCh1cmwsIHRva2VuPU5vbmUsIGRhdGE9Tm9uZSk6CiAgICBoZWFkZXJzID0geydVc2VyLUFnZW50JzogJ1doYWxlTm9kZS1JbnN0YWxsZXIvMScsICdBY2NlcHQnOiAnYXBwbGljYXRpb24vanNvbid9CiAgICBpZiB0b2tlbjoKICAgICAgICBoZWFkZXJzWydBdXRob3JpemF0aW9uJ10gPSB0b2tlbgogICAgaWYgZGF0YSBpcyBub3QgTm9uZToKICAgICAgICBoZWFkZXJzWydDb250ZW50LVR5cGUnXSA9ICdhcHBsaWNhdGlvbi9qc29uJwogICAgcmVxID0gdXJsbGliLnJlcXVlc3QuUmVxdWVzdChodHRwcyh1cmwpLCBkYXRhPU5vbmUgaWYgZGF0YSBpcyBOb25lIGVsc2UganNvbi5kdW1wcyhkYXRhKS5lbmNvZGUoKSwgaGVhZGVycz1oZWFkZXJzKQogICAgdHJ5OgogICAgICAgIHdpdGggdXJsbGliLnJlcXVlc3QuYnVpbGRfb3BlbmVyKE5vUmVkaXJlY3QoKSkub3BlbihyZXEsIHRpbWVvdXQ9NjApIGFzIHJlc3BvbnNlOgogICAgICAgICAgICByYXc9cmVzcG9uc2UucmVhZCgxNioxMDI0KjEwMjQrMSkKICAgICAgICAgICAgaWYgbGVuKHJhdyk+MTYqMTAyNCoxMDI0OnJhaXNlIFJ1bnRpbWVFcnJvcignQVBJIOWTjeW6lOi2hei/h+Wkp+Wwj+mZkOWIticpCiAgICAgICAgICAgIHJldHVybiBqc29uLmxvYWRzKHJhdykKICAgIGV4Y2VwdCB1cmxsaWIuZXJyb3IuSFRUUEVycm9yIGFzIGU6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdBUEkg6K+35rGC5aSx6LSl77yMSFRUUCDnirbmgIHnoIHvvJonICsgc3RyKGUuY29kZSkpIGZyb20gTm9uZQogICAgZXhjZXB0ICh1cmxsaWIuZXJyb3IuVVJMRXJyb3IsIFZhbHVlRXJyb3IpOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcignQVBJIOivt+axguWksei0peaIlui/lOWbnuWGheWuueS4jeaYr+acieaViCBKU09OJykgZnJvbSBOb25lCgpkZWYgaXB2NF9yZXF1ZXN0KHVybCk6CiAgICAiIiLlj4zmoIjmnLrlmajpu5jorqTotbAgSVB2Nu+8jOafpeWIsOeahOaYryBJUHY2IOWHuuWPo++8m+WFpeWPo+W/hemhu+aYr+WFrOe9kSBJUHY077yM5omA5Lul5Y+q55SoIElQdjQg6L+e5o6l44CCIiIiCiAgICBvcmlnaW5hbD1zb2NrZXQuZ2V0YWRkcmluZm8KICAgIGRlZiBvbmx5X3Y0KGhvc3QscG9ydCxmYW1pbHk9MCwqcmVzdCwqKmt3KToKICAgICAgICByZXR1cm4gb3JpZ2luYWwoaG9zdCxwb3J0LHNvY2tldC5BRl9JTkVULCpyZXN0LCoqa3cpCiAgICBzb2NrZXQuZ2V0YWRkcmluZm89b25seV92NAogICAgdHJ5OnJldHVybiByZXF1ZXN0KHVybCkKICAgIGV4Y2VwdCBSdW50aW1lRXJyb3I6cmFpc2UgUnVudGltZUVycm9yKCfml6Dms5XpgJrov4cgSVB2NCDor4bliKvlhaznvZHlnLDlnYDvvJvmnKzmnLrpnIDopoHlhaznvZEgSVB2NO+8jOaIlueUqCAtLWhvc3Qg5oyH5a6aJykgZnJvbSBOb25lCiAgICBmaW5hbGx5OnNvY2tldC5nZXRhZGRyaW5mbz1vcmlnaW5hbAoKZGVmIGF0b21pYyhwYXRoLCB0ZXh0LCBtb2RlPTBvNjAwKToKICAgIHBhdGggPSBQYXRoKHBhdGgpCiAgICBwYXRoLnBhcmVudC5ta2RpcihwYXJlbnRzPVRydWUsIGV4aXN0X29rPVRydWUpCiAgICBmZCwgdG1wID0gdGVtcGZpbGUubWtzdGVtcChkaXI9c3RyKHBhdGgucGFyZW50KSkKICAgIHRyeToKICAgICAgICBvcy5mY2htb2QoZmQsIG1vZGUpCiAgICAgICAgd2l0aCBvcy5mZG9wZW4oZmQsICd3JykgYXMgZjoKICAgICAgICAgICAgZi53cml0ZSh0ZXh0KQogICAgICAgICAgICBmLmZsdXNoKCkKICAgICAgICAgICAgb3MuZnN5bmMoZi5maWxlbm8oKSkKICAgICAgICBvcy5yZXBsYWNlKHRtcCwgcGF0aCkKICAgIGZpbmFsbHk6CiAgICAgICAgaWYgb3MucGF0aC5leGlzdHModG1wKToKICAgICAgICAgICAgb3MudW5saW5rKHRtcCkKCmRlZiBib3VuZGVkX2NvcHkoc291cmNlLG91dCxsaW1pdCk6CiAgICB0b3RhbD0wCiAgICB3aGlsZSBUcnVlOgogICAgICAgIGJsb2NrPXNvdXJjZS5yZWFkKDEwMjQqMTAyNCkKICAgICAgICBpZiBub3QgYmxvY2s6cmV0dXJuCiAgICAgICAgdG90YWwrPWxlbihibG9jaykKICAgICAgICBpZiB0b3RhbD5saW1pdDpyYWlzZSBSdW50aW1lRXJyb3IoJ+WPkeW4g+WMhei2hei/h+WFgeiuuOWkp+Wwj++8jOW3suWBnOatouS4i+i9veaIluino+WOiycpCiAgICAgICAgb3V0LndyaXRlKGJsb2NrKQoKZGVmIHJlc291cmNlcygpOgogICAgY3B1ID0gbGVuKG9zLnNjaGVkX2dldGFmZmluaXR5KDApKQogICAgbWVtID0gaW50KG5leHQoeC5zcGxpdCgpWzFdIGZvciB4IGluIFBhdGgoJy9wcm9jL21lbWluZm8nKS5yZWFkX3RleHQoKS5zcGxpdGxpbmVzKCkgaWYgeC5zdGFydHN3aXRoKCdNZW1Ub3RhbDonKSkpIC8vIDEwMjQKICAgIGZvciBwYXRoIGluICgnL3N5cy9mcy9jZ3JvdXAvbWVtb3J5Lm1heCcsICcvc3lzL2ZzL2Nncm91cC9tZW1vcnkvbWVtb3J5LmxpbWl0X2luX2J5dGVzJyk6CiAgICAgICAgaWYgUGF0aChwYXRoKS5pc19maWxlKCk6CiAgICAgICAgICAgIHZhbHVlID0gUGF0aChwYXRoKS5yZWFkX3RleHQoKS5zdHJpcCgpCiAgICAgICAgICAgIGlmIHZhbHVlLmlzZGlnaXQoKTogbWVtID0gbWluKG1lbSwgaW50KHZhbHVlKSAvLyAxMDQ4NTc2KQogICAgaWYgUGF0aCgnL3N5cy9mcy9jZ3JvdXAvY3B1Lm1heCcpLmlzX2ZpbGUoKToKICAgICAgICBxdW90YSwgcGVyaW9kID0gUGF0aCgnL3N5cy9mcy9jZ3JvdXAvY3B1Lm1heCcpLnJlYWRfdGV4dCgpLnNwbGl0KCkKICAgICAgICBpZiBxdW90YSAhPSAnbWF4JzogY3B1ID0gbWluKGNwdSwgbWF4KDEsIG1hdGguY2VpbChpbnQocXVvdGEpIC8gaW50KHBlcmlvZCkpKSkKICAgIGVsc2U6CiAgICAgICAgcSA9IFBhdGgoJy9zeXMvZnMvY2dyb3VwL2NwdS9jcHUuY2ZzX3F1b3RhX3VzJykKICAgICAgICBwID0gUGF0aCgnL3N5cy9mcy9jZ3JvdXAvY3B1L2NwdS5jZnNfcGVyaW9kX3VzJykKICAgICAgICBpZiBxLmlzX2ZpbGUoKSBhbmQgcC5pc19maWxlKCkgYW5kIGludChxLnJlYWRfdGV4dCgpKSA+IDA6CiAgICAgICAgICAgIGNwdSA9IG1pbihjcHUsIG1heCgxLCBtYXRoLmNlaWwoaW50KHEucmVhZF90ZXh0KCkpIC8gaW50KHAucmVhZF90ZXh0KCkpKSkpCiAgICBpZiBtZW0gPCA3Njg6IHJhaXNlIFJ1bnRpbWVFcnJvcign6Iez5bCR6ZyA6KaBIDc2OCBNaUIg5Y+v55So5YaF5a2Y6YWN6aKdJykKICAgIHJldHVybiB7J2NwdXMnOiBjcHUsICdtZW1vcnlfbWliJzogbWVtLCAnZ29fbWVtb3J5X21pYic6IG1pbihpbnQobWVtICogLjYpLCBtZW0gLSAzODQpLAogICAgICAgICAgICAnc29ja2V0X2J1ZmZlcic6IG1pbigxNjc3NzIxNiwgbWF4KDIwOTcxNTIsIG1lbSAqIDEwMjQpKSwKICAgICAgICAgICAgJ2ludGVyZmFjZXMnOiBzb3J0ZWQocC5uYW1lIGZvciBwIGluIFBhdGgoJy9zeXMvY2xhc3MvbmV0JykuaXRlcmRpcigpIGlmIHAubmFtZSAhPSAnbG8nKX0KCmRlZiBwYXJzZXIoKToKICAgIHAgPSBhcmdwYXJzZS5Bcmd1bWVudFBhcnNlcihkZXNjcmlwdGlvbj1fX2RvY19fKQogICAgZm9yIG5hbWUgaW4gKCdhcGktdXJsJywnYXBpLWtleScsJ2FkbWluLXVybCcsJ2FkbWluLXRva2VuJywnYmluYXJ5LXVybCcsJ2JpbmFyeS1zaGEyNTYnLCdzb3VyY2UtY29tbWl0JywnaG9zdCcsJ25hbWUnKToKICAgICAgICBwLmFkZF9hcmd1bWVudCgnLS0nICsgbmFtZSkKICAgIHAuYWRkX2FyZ3VtZW50KCctLWFwaS1rZXktZmlsZScsIHR5cGU9UGF0aCkKICAgIHAuYWRkX2FyZ3VtZW50KCctLWFkbWluLXRva2VuLWZpbGUnLCB0eXBlPVBhdGgpCiAgICBwLmFkZF9hcmd1bWVudCgnLS1wcm90b2NvbHMnLCBkZWZhdWx0PU5vbmUpCiAgICBwLmFkZF9hcmd1bWVudCgnLS1ncm91cC1pZHMnKQogICAgcC5hZGRfYXJndW1lbnQoJy0tcm91dGUtaWRzJykKICAgIHAuYWRkX2FyZ3VtZW50KCctLXNuaScsIGRlZmF1bHQ9Tm9uZSwgaGVscD0n5Y+v6YCJ77yb5oyH5a6a5bey5rWL6K+V5Y+v55So55qEIFRMUyDln5/lkI0nKQogICAgbW9kZT1wLmFkZF9tdXR1YWxseV9leGNsdXNpdmVfZ3JvdXAoKQogICAgbW9kZS5hZGRfYXJndW1lbnQoJy0tc3RhdHVzJywgYWN0aW9uPSdzdG9yZV90cnVlJykKICAgIG1vZGUuYWRkX2FyZ3VtZW50KCctLWNoZWNrJywgYWN0aW9uPSdzdG9yZV90cnVlJywgaGVscD0n5Y+q6K+75qOA5p+l6L+Q6KGM5paH5Lu244CB55uR5ZCs44CB6YWN572u5p2D6ZmQ5Y+KIElQdjYg5Ye65Y+j6KeE5YiZJykKICAgIHAuYWRkX2FyZ3VtZW50KCctLXJlcG9ydC1maWxlJywgdHlwZT1QYXRoLCBoZWxwPSfphY3lkIggLS1jaGVjayDovpPlh7rkuI3lkKvlh63mja7nmoQgSlNPTiDpqozmlLbmiqXlkYonKQogICAgcC5hZGRfYXJndW1lbnQoJy0tZG93bmxvYWQtdG9rZW4tZmlsZScsIHR5cGU9UGF0aCwgaGVscD0n56eB5pyJ5LiL6L29IEJlYXJlciDku6TniYzmlofku7bvvIzku4XmnKzmrKHkvb/nlKgnKQogICAgcC5hZGRfYXJndW1lbnQoJy0tZG93bmxvYWQtdG9rZW4nLCBoZWxwPSfnp4HmnInkuIvovb0gQmVhcmVyIOS7pOeJjO+8iOS8mui/m+WFpeWRveS7pOWOhuWPsu+8m+S8mOWFiOeUqOaWh+S7tuaIlumakOiXj+i+k+WFpe+8iScpCiAgICBwLmFkZF9hcmd1bWVudCgnLS1kb3dubG9hZC10b2tlbi1wcm9tcHQnLCBhY3Rpb249J3N0b3JlX3RydWUnLCBoZWxwPSfpmpDol4/ovpPlhaXnp4HmnInkuIvovb0gQmVhcmVyIOS7pOeJjCcpCiAgICBtb2RlLmFkZF9hcmd1bWVudCgnLS1wbGFuJywgYWN0aW9uPSdzdG9yZV90cnVlJykKICAgIHAuYWRkX2FyZ3VtZW50KCctLW5vbi1pbnRlcmFjdGl2ZScsIGFjdGlvbj0nc3RvcmVfdHJ1ZScsIGhlbHA9J+emgeatouS6pOS6ku+8jOe8uuWwkeWPguaVsOaXtuebtOaOpeaKpemUmScpCiAgICBwLmFkZF9hcmd1bWVudCgnLS1yZWxlYXNlLW1hbmlmZXN0JywgaGVscD0nSFRUUFMg5Y+R5biD5riF5Y2V77yM6Ieq5Yqo6YCJ5oup5p625p6E5Y+K5qCh6aqM5YC8JykKICAgIG1vZGUuYWRkX2FyZ3VtZW50KCctLXJvbGxiYWNrJywgYWN0aW9uPSdzdG9yZV90cnVlJywgaGVscD0n5YGc5q2i5pys5Lu75Yqh5pyN5Yqh5bm25oGi5aSN5pys5Lu75Yqh5L+u5pS555qE57O757uf5Y+C5pWw77yb5L+d55WZ6ZqQ6JeP6Z2i5p2/6IqC54K5JykKICAgIG1vZGUuYWRkX2FyZ3VtZW50KCctLXJldHVuZScsIGFjdGlvbj0nc3RvcmVfdHJ1ZScsIGhlbHA9J+WNh+e6pyBDUFUv5YaF5a2Y5ZCO5omn6KGM77ya5oyJ5b2T5YmN6YWN572u6YeN566X5ZCO56uvIENQVS/lhoXlrZjkuIrpmZDkuI7lhoXmoLjlj4LmlbDvvIzkv67mraPnvZHljaHpmJ/liJfnrpfms5XvvIjkuIrpmZDlj5jljJbml7bph43lkK/lkI7nq6/mlbDnp5LvvIknKQogICAgbW9kZS5hZGRfYXJndW1lbnQoJy0taGlkZScsIGFjdGlvbj0nc3RvcmVfdHJ1ZScsIGhlbHA9J+mdouadv+makOiXj+acrOacuuiKgueCue+8iOeUqOaIt+S4jeWGjeaUtuWIsO+8iScpCiAgICBtb2RlLmFkZF9hcmd1bWVudCgnLS1zaG93JywgYWN0aW9uPSdzdG9yZV90cnVlJywgaGVscD0n6Z2i5p2/6YeN5paw5pi+56S65pys5py66IqC54K5JykKICAgIG1vZGUuYWRkX2FyZ3VtZW50KCctLXVuaW5zdGFsbCcsIGFjdGlvbj0nc3RvcmVfdHJ1ZScsIGhlbHA9J+makOiXj+W5tuWIoOmZpOmdouadv+iKgueCue+8jOWNuOi9veacrOacuuacjeWKoeWSjOebkeaOpycpCiAgICBwLmFkZF9hcmd1bWVudCgnLS15ZXMnLCBhY3Rpb249J3N0b3JlX3RydWUnLCBoZWxwPSfljbjovb3ml7bkuI3lho3noa7orqQnKQogICAgIyBCb29sZWFuT3B0aW9uYWxBY3Rpb24gd2FzIGludHJvZHVjZWQgaW4gUHl0aG9uIDMuOSAoVWJ1bnR1IDIwLjA0IGhhcyAzLjgpLgogICAgcC5hZGRfYXJndW1lbnQoJy0tcHVibGlzaCcsIGFjdGlvbj0nc3RvcmVfdHJ1ZScsIGRlZmF1bHQ9Tm9uZSwKICAgICAgICAgICAgICAgICAgIGhlbHA9J+WuieijheWQjuebtOaOpeWcqOmdouadv+aYvuekuu+8iOm7mOiupOW8gOWQr++8my0tbm8tcHVibGlzaCDkv53mjIHpmpDol4/vvIknKQogICAgcC5hZGRfYXJndW1lbnQoJy0tbm8tcHVibGlzaCcsIGRlc3Q9J3B1Ymxpc2gnLCBhY3Rpb249J3N0b3JlX2ZhbHNlJywgZGVmYXVsdD1Ob25lLAogICAgICAgICAgICAgICAgICAgaGVscD0n5a6J6KOF5ZCO5L+d5oyB6Z2i5p2/6ZqQ6JePJykKICAgIHAuYWRkX2FyZ3VtZW50KCctLW5vZGUtZ3JvdXAnLCBoZWxwPSfnvZHlhbPoioLngrnliIbnu4TvvIzpu5jorqQgbGVnYWN5X2FsbCcpCiAgICByZXR1cm4gcAoKZGVmIHByb21wdCh0ZXh0LCBkZWZhdWx0PScnLCByZXF1aXJlZD1GYWxzZSk6CiAgICB0cnk6CiAgICAgICAgd2l0aCBvcGVuKCcvZGV2L3R0eScsJ3InLGVuY29kaW5nPSd1dGYtOCcpIGFzIHJlYWRlciwgb3BlbignL2Rldi90dHknLCd3JyxlbmNvZGluZz0ndXRmLTgnLGJ1ZmZlcmluZz0xKSBhcyB0dHk6CiAgICAgICAgICAgIHdoaWxlIFRydWU6CiAgICAgICAgICAgICAgICB0dHkud3JpdGUodGV4dCsoJyBbJytkZWZhdWx0KyddJyBpZiBkZWZhdWx0IGVsc2UgJycpKyc6ICcpCiAgICAgICAgICAgICAgICB0dHkuZmx1c2goKQogICAgICAgICAgICAgICAgbGluZT1yZWFkZXIucmVhZGxpbmUoKQogICAgICAgICAgICAgICAgaWYgbm90IGxpbmU6IHJhaXNlIFJ1bnRpbWVFcnJvcign57uI56uv6L6T5YWl5bey5YWz6ZetJykKICAgICAgICAgICAgICAgIHZhbHVlPWxpbmUuc3RyaXAoKSBvciBkZWZhdWx0CiAgICAgICAgICAgICAgICBpZiB2YWx1ZSBvciBub3QgcmVxdWlyZWQ6cmV0dXJuIHZhbHVlCiAgICAgICAgICAgICAgICB0dHkud3JpdGUoJ+atpOmhueS4jeiDveS4uuepuuOAglxuJykKICAgIGV4Y2VwdCBPU0Vycm9yOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcign5rKh5pyJ5Lqk5LqS57uI56uv77yM6K+36YCa6L+H5Y+C5pWw5o+Q5L6b6YWN572u5oiW5L2/55SoIFNTSCDnu4jnq6/miafooYwnKSBmcm9tIE5vbmUKCmRlZiBvcmlnaW4odXJsKToKICAgIHA9dXJsbGliLnBhcnNlLnVybHNwbGl0KGh0dHBzKHVybCkpCiAgICByZXR1cm4gKHAuc2NoZW1lLHAuaG9zdG5hbWUubG93ZXIoKSxwLnBvcnQgb3IgNDQzKQoKZGVmIGRvd25sb2FkX2F1dGgoYXJncywgdXJsLCBhbGxvd2VkX29yaWdpbik6CiAgICB0b2tlbj1nZXRhdHRyKGFyZ3MsJ19kb3dubG9hZF90b2tlbicsTm9uZSkKICAgIGlmIG5vdCB0b2tlbjpyZXR1cm4gTm9uZQogICAgaWYgb3JpZ2luKHVybCkhPW9yaWdpbihhbGxvd2VkX29yaWdpbik6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCfnp4HmnInliLblk4HkuIvovb3lnLDlnYDkuI7pibTmnYPmnaXmupDkuI3lkIzvvIzmi5Lnu53ovazlj5HkuIvovb3ku6TniYwnKQogICAgcmV0dXJuICdCZWFyZXIgJyt0b2tlbgoKZGVmIHByZXBhcmVfZG93bmxvYWRfYXV0aChhcmdzKToKICAgIGlmIHN1bShtYXAoYm9vbCwoYXJncy5kb3dubG9hZF90b2tlbixhcmdzLmRvd25sb2FkX3Rva2VuX2ZpbGUsYXJncy5kb3dubG9hZF90b2tlbl9wcm9tcHQpKSk+MToKICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCfkuIvovb3ku6TniYzlj6rog73nlKjkuIDnp43mlrnlvI/mj5DkvpsnKQogICAgaWYgYXJncy5kb3dubG9hZF90b2tlbl9wcm9tcHQgYW5kIGFyZ3Mubm9uX2ludGVyYWN0aXZlOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoJ+mdnuS6pOS6kuaooeW8j+ivt+S9v+eUqCAtLWRvd25sb2FkLXRva2VuLWZpbGUnKQogICAgdG9rZW49YXJncy5kb3dubG9hZF90b2tlbgogICAgaWYgYXJncy5kb3dubG9hZF90b2tlbl9maWxlOgogICAgICAgIGZkPW9zLm9wZW4oYXJncy5kb3dubG9hZF90b2tlbl9maWxlLG9zLk9fUkRPTkxZfG9zLk9fTk9GT0xMT1d8b3MuT19OT05CTE9DSykKICAgICAgICB3aXRoIG9zLmZkb3BlbihmZCkgYXMgZjoKICAgICAgICAgICAgbW9kZT1vcy5mc3RhdChmLmZpbGVubygpKQogICAgICAgICAgICBpZiBub3Qgc3RhdC5TX0lTUkVHKG1vZGUuc3RfbW9kZSkgb3IgbW9kZS5zdF91aWQhPTAgb3IgbW9kZS5zdF9tb2RlICYgMG8wNzc6CiAgICAgICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCfkuIvovb3ku6TniYzmlofku7blv4XpobvnlLEgcm9vdCDmiYDmnInvvIzkuJTkuI3lj6/ooqvnu4TmiJblhbbku5bnlKjmiLfor7vlj5YnKQogICAgICAgICAgICB0b2tlbj1mLnJlYWQoODE5Mykuc3RyaXAoKQogICAgZWxpZiBhcmdzLmRvd25sb2FkX3Rva2VuX3Byb21wdDoKICAgICAgICB0b2tlbj1nZXRwYXNzLmdldHBhc3MoJ+ivt+i+k+WFpeengeacieS4i+i9veS7pOeJjO+8iOmakOiXj+i+k+WFpe+8jOS4jeS/neWtmO+8ie+8micpCiAgICBpZiB0b2tlbiBpcyBub3QgTm9uZSBhbmQgKG5vdCB0b2tlbiBvciBsZW4odG9rZW4pPjgxOTIgb3IgYW55KG9yZChjKTwzMyBvciBvcmQoYyk+MTI2IGZvciBjIGluIHRva2VuKSk6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcign5LiL6L295Luk54mM5qC85byP5peg5pWIJykKICAgIGFyZ3MuX2Rvd25sb2FkX3Rva2VuPXRva2VuCgpkZWYgbWFuaWZlc3QodXJsLCBtYWNoaW5lPU5vbmUsIHRva2VuPU5vbmUpOgogICAgbWFjaGluZT1tYWNoaW5lIG9yIHBsYXRmb3JtLm1hY2hpbmUoKQogICAgYXJjaD17J3g4Nl82NCc6J2FtZDY0JywnYWFyY2g2NCc6J2FybTY0J30uZ2V0KG1hY2hpbmUpCiAgICBpZiBub3QgYXJjaDpyYWlzZSBWYWx1ZUVycm9yKCfkuI3mlK/mjIHnmoQgQ1BVIOaetuaehO+8micrbWFjaGluZSkKICAgIGRvYz1yZXF1ZXN0KHVybCx0b2tlbikgaWYgdG9rZW4gZWxzZSByZXF1ZXN0KHVybCkKICAgIGVudHJ5PWRvYy5nZXQoJ2FyY2hpdGVjdHVyZXMnLHt9KS5nZXQoYXJjaCkKICAgIGlmIGRvYy5nZXQoJ3NjaGVtYScpIT0xIG9yIG5vdCBpc2luc3RhbmNlKGVudHJ5LGRpY3QpOnJhaXNlIFZhbHVlRXJyb3IoJ+WPkeW4g+a4heWNleacquaPkOS+m+W9k+WJjeaetuaehO+8micrYXJjaCkKICAgIGh0dHBzKGVudHJ5LmdldCgndXJsJywnJykpCiAgICBpZiBub3QgcmUuZnVsbG1hdGNoKCdbYS1mMC05XXs2NH0nLGVudHJ5LmdldCgnc2hhMjU2JywnJykpIG9yIG5vdCByZS5mdWxsbWF0Y2goJ1thLWYwLTldezQwfScsZW50cnkuZ2V0KCdzb3VyY2VfY29tbWl0JywnJykpOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoJ+WPkeW4g+a4heWNleeahOagoemqjOWAvOaIlua6kOeggeaPkOS6pOWPt+aXoOaViCcpCiAgICBvdXQ9eydiaW5hcnlfdXJsJzplbnRyeVsndXJsJ10sJ2JpbmFyeV9zaGEyNTYnOmVudHJ5WydzaGEyNTYnXSwnc291cmNlX2NvbW1pdCc6ZW50cnlbJ3NvdXJjZV9jb21taXQnXX0KICAgIG91dC51cGRhdGUobW9uaXRvcl9lbnRyeShkb2MpKQogICAgcmV0dXJuIG91dAoKZGVmIG1vbml0b3JfZW50cnkoZG9jKToKICAgIG1vbj1kb2MuZ2V0KCdtb25pdG9yJykKICAgIGlmIG5vdCBpc2luc3RhbmNlKG1vbixkaWN0KTpyZXR1cm4ge30KICAgIGh0dHBzKG1vbi5nZXQoJ3VybCcsJycpKQogICAgaWYgbm90IHJlLmZ1bGxtYXRjaCgnW2EtZjAtOV17NjR9Jyxtb24uZ2V0KCdzaGEyNTYnLCcnKSk6cmFpc2UgVmFsdWVFcnJvcign5Y+R5biD5riF5Y2V55qE55uR5o6n5o6l5YWl5YyF5qCh6aqM5YC85peg5pWIJykKICAgIHJldHVybiB7J21vbml0b3JfdXJsJzptb25bJ3VybCddLCdtb25pdG9yX3NoYTI1Nic6bW9uWydzaGEyNTYnXX0KCmRlZiB3aXphcmQoYXJncyxzdGF0ZSk6CiAgICBpbnRlcmFjdGl2ZT1ub3QgYXJncy5ub25faW50ZXJhY3RpdmUKICAgIGZvciBuYW1lLGxhYmVsIGluIFsoJ2FwaV91cmwnLCfoioLngrkgQVBJIOeahCBIVFRQUyDlnLDlnYAnKSwoJ2FkbWluX3VybCcsJ+mdouadv+euoeeQhiBBUEkg5YmN57yA77yI5ZCrIC9hcGkvdjEv566h55CG6Lev5b6E77yJJyldOgogICAgICAgIGlmIG5vdCBnZXRhdHRyKGFyZ3MsbmFtZSkgYW5kIG5vdCBzdGF0ZS5nZXQobmFtZSk6CiAgICAgICAgICAgIGlmIG5vdCBpbnRlcmFjdGl2ZTpyYWlzZSBWYWx1ZUVycm9yKCfnvLrlsJHlj4LmlbAgLS0nK25hbWUucmVwbGFjZSgnXycsJy0nKSkKICAgICAgICAgICAgc2V0YXR0cihhcmdzLG5hbWUscHJvbXB0KGxhYmVsLHJlcXVpcmVkPVRydWUpKQogICAgaWYgbm90IGFyZ3MucHJvdG9jb2xzIGFuZCBub3Qgc3RhdGUuZ2V0KCdwcm90b2NvbHMnKSBhbmQgaW50ZXJhY3RpdmU6CiAgICAgICAgYXJncy5wcm90b2NvbHM9cHJvbXB0KCfpgInmi6nljY/orq7vvIzpgJflj7flpJrpgInvvJp2bGVzcyAvIGh5MiAvIGFueXRscycsJ3ZsZXNzLGh5MicpCiAgICBpZiBhcmdzLm5hbWUgaXMgTm9uZSBhbmQgbm90IHN0YXRlLmdldCgnbmFtZScpIGFuZCBpbnRlcmFjdGl2ZToKICAgICAgICBhcmdzLm5hbWU9cHJvbXB0KCfoioLngrnlkI3np7DvvIjnm7TmjqXlm57ovaboh6rliqjmjInlnLDljLrlkb3lkI3vvIknKSBvciBOb25lCiAgICBpZiBhcmdzLmdyb3VwX2lkcyBpcyBOb25lIGFuZCBub3Qgc3RhdGUuZ2V0KCdncm91cHMnKSBhbmQgaW50ZXJhY3RpdmU6CiAgICAgICAgYXJncy5ncm91cF9pZHM9cHJvbXB0KCfpnaLmnb/mnYPpmZDnu4QgSUTvvIzpgJflj7fliIbpmpQnLCcxJykKICAgIGlmIGFyZ3Mucm91dGVfaWRzIGlzIE5vbmUgYW5kICdyb3V0ZXMnIG5vdCBpbiBzdGF0ZSBhbmQgaW50ZXJhY3RpdmU6CiAgICAgICAgYXJncy5yb3V0ZV9pZHM9cHJvbXB0KCfpnaLmnb/ot6/nlLHnu4QgSUTvvIjlm57ovabkuI3mjIflrprvvIknKQogICAgcmVsZWFzZT1hcmdzLnJlbGVhc2VfbWFuaWZlc3Qgb3Igc3RhdGUuZ2V0KCdyZWxlYXNlX21hbmlmZXN0JykKICAgIGlmIG5vdCByZWxlYXNlIGFuZCBub3QgKGFyZ3MuYmluYXJ5X3VybCBvciBzdGF0ZS5nZXQoJ2JpbmFyeV91cmwnKSk6CiAgICAgICAgaWYgbm90IGludGVyYWN0aXZlOnJhaXNlIFZhbHVlRXJyb3IoJ+e8uuWwkSAtLXJlbGVhc2UtbWFuaWZlc3Qg5oiWIC0tYmluYXJ5LXVybCcpCiAgICAgICAgcmVsZWFzZT1wcm9tcHQoJ1doYWxlTm9kZSBIVFRQUyDlj5HluIPmuIXljZXlnLDlnYDvvIjoh6rliqjpgInmi6nniYjmnKzlkozmoKHpqozlgLzvvIknLHJlcXVpcmVkPVRydWUpCiAgICBpZiByZWxlYXNlOgogICAgICAgIGlmIHN0YXRlLmdldCgncmVsZWFzZV9tYW5pZmVzdCcpIGFuZCByZWxlYXNlIT1zdGF0ZVsncmVsZWFzZV9tYW5pZmVzdCddIGFuZCBzdGF0ZS5nZXQoJ2lkcycpOgogICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCfnu63ot5HkuI3og73mm7TmjaLlt7Lkvb/nlKjnmoTlj5HluIPmuIXljZUnKQogICAgICAgIGlmIG5vdCBhbGwoc3RhdGUuZ2V0KGspIGZvciBrIGluICgnYmluYXJ5X3VybCcsJ2JpbmFyeV9zaGEyNTYnLCdzb3VyY2VfY29tbWl0JykpOgogICAgICAgICAgICBhdXRoPWRvd25sb2FkX2F1dGgoYXJncyxyZWxlYXNlLHJlbGVhc2UpCiAgICAgICAgICAgIHN0YXRlLnVwZGF0ZShtYW5pZmVzdChyZWxlYXNlLHRva2VuPWF1dGgpIGlmIGF1dGggZWxzZSBtYW5pZmVzdChyZWxlYXNlKSkKICAgICAgICBzdGF0ZVsncmVsZWFzZV9tYW5pZmVzdCddPXJlbGVhc2UKICAgIGVsc2U6CiAgICAgICAgZm9yIG5hbWUsbGFiZWwgaW4gWygnYmluYXJ5X3NoYTI1NicsJ+WPr+aJp+ihjOaWh+S7tiBTSEEyNTYnKSwoJ3NvdXJjZV9jb21taXQnLCflrozmlbTmupDnoIHmj5DkuqQgU0hBJyldOgogICAgICAgICAgICBpZiBub3QgZ2V0YXR0cihhcmdzLG5hbWUpIGFuZCBub3Qgc3RhdGUuZ2V0KG5hbWUpIGFuZCBpbnRlcmFjdGl2ZToKICAgICAgICAgICAgICAgIHNldGF0dHIoYXJncyxuYW1lLHByb21wdChsYWJlbCxyZXF1aXJlZD1UcnVlKSkKCiMg5Y6G5Y+y5py66Zif5rGgICsg546w5pyJIGZpbmRlciDmlrDnrZvpgInnu5PmnpzvvJvmnaXmupDlkozmtYvph4/ojIPlm7Top4Egc25pLXBvb2wtcHJvdmVuYW5jZS5qc29u44CCClNOSV9QT09MPSgKICAgICd3d3cuaW50ZWwuY29tJywKICAgICd3d3cubGcuY29tJywKICAgICd3d3cucHl0aG9uLm9yZycsCiAgICAnd3d3LnF1YWxjb21tLmNvbScsCiAgICAnd3d3LnNhbXN1bmcuY29tJywKICAgICd3d3cucG9zdGdyZXNxbC5vcmcnLAogICAgJ3d3dy5rZXJuZWwub3JnJywKICAgICd3d3cudGVzbGEuY29tJywKICAgICd3d3cuc29ueS5jb20nLAogICAgJ3d3dy5zcGVlZHRlc3QubmV0JywKICAgICd3d3cuY2lzY28uY29tJywKICAgICd3d3cub3JhY2xlLmNvbScsCiAgICAnd3d3LmlibS5jb20nLAogICAgJ3d3dy5kZWxsLmNvbScsCiAgICAnd3d3LmFzdXMuY29tJywKICAgICd3d3cuc2llbWVucy5jb20nLAogICAgJ3d3dy5waGlsaXBzLmNvbScsCiAgICAnd3d3LmNhbm9uLmNvbScsCiAgICAnd3d3LmVwc29uLmNvbScsCiAgICAnd3d3Lm5va2lhLmNvbScsCiAgICAnd3d3LnNhcC5jb20nLAogICAgJ3d3dy54ZXJveC5jb20nLAogICAgJ3d3dy5mdWppdHN1LmNvbScsCiAgICAnd3d3LmRlYmlhbi5vcmcnLAogICAgJ3d3dy5yZWRoYXQuY29tJywKICAgICd3d3cuamV0YnJhaW5zLmNvbScsCiAgICAnd3d3Lmxlbm92by5jb20nLAogICAgJ3d3dy5ib3NjaC5jb20nLAogICAgJ3d3dy5wYW5hc29uaWMuY29tJywKICAgICd3d3cudG9zaGliYS5jb20nLAogICAgJ3d3dy5sb2dpdGVjaC5jb20nLAogICAgJ3d3dy5hdXRvZGVzay5jb20nLAogICAgJ3d3dy5hZG9iZS5jb20nLAogICAgJ3d3dy5hdGxhc3NpYW4uY29tJywKICAgICd3d3cuc3BvdGlmeS5jb20nLAogICAgJ3d3dy5ib29raW5nLmNvbScsCiAgICAnd3d3LmFiYi5jb20nLAogICAgJ3d3dy5zY2huZWlkZXItZWxlY3RyaWMuY29tJywKICAgICd3d3cuYm13LmNvbScsCiAgICAnd3d3LnZvbGtzd2FnZW4uY29tJywKICAgICd3d3cuc2hlbGwuY29tJywKICAgICd3d3cuYWlyYnVzLmNvbScsCiAgICAnd3d3LnJpY29oLmNvbScsCiAgICAnd3d3LmJyb3RoZXIuY29tJywKICAgICd3d3cuemVpc3MuY29tJywKICAgICd3d3cuYmF5ZXIuY29tJywKICAgICd3d3cuYmFzZi5jb20nLAogICAgJ3d3dy5ueHAuY29tJywKICAgICd3d3cuaW5maW5lb24uY29tJywKICAgICd3d3cuc3QuY29tJywKICAgICd3d3cuYXJtLmNvbScsCiAgICAnd3d3Lm1pY3Jvbi5jb20nLAogICAgJ3d3dy5qdW5pcGVyLm5ldCcsCiAgICAnd3d3LmFyaXN0YS5jb20nLAogICAgJ3d3dy5uZXRhcHAuY29tJywKICAgICd3d3cuY2l0cml4LmNvbScsCiAgICAnd3d3LmFwYWNoZS5vcmcnLAogICAgJ3d3dy5waHAubmV0JywKICAgICd3d3cucnVzdC1sYW5nLm9yZycsCiAgICAnd3d3LnRoYWxlc2dyb3VwLmNvbScsCiAgICAnd3d3LmNvbnRpbmVudGFsLmNvbScsCiAgICAnd3d3Lm9seW1wdXMtZ2xvYmFsLmNvbScsCiAgICAnd3d3LnlhbWFoYS5jb20nLAogICAgJ3d3dy5kZW5zby5jb20nLAogICAgJ2xpbmtlZGluLmNvbScsCiAgICAnZ29vZ2xldGFnbWFuYWdlci5jb20nLAogICAgJ25ldGZsaXguY29tJywKICAgICd3b3JkcHJlc3Mub3JnJywKICAgICdnb28uZ2wnLAogICAgJ25pYy5ydScsCiAgICAnd29yZHByZXNzLmNvbScsCiAgICAndmsuY29tJywKICAgICdhcGFjaGUub3JnJywKICAgICdhcHAtbWVhc3VyZW1lbnQuY29tJywKICAgICdnb29nbGVhZHNlcnZpY2VzLmNvbScsCiAgICAnYXBwLWFuYWx5dGljcy1zZXJ2aWNlcy5jb20nLAogICAgJ3Byb2RyZWdpc3RyeXYyLm9yZycsCiAgICAnZG5zLmdvb2dsZScsCiAgICAnZm9ybXMuZ2xlJywKICAgICdncmF2YXRhci5jb20nLAogICAgJ2FyY2hpdmUub3JnJywKICAgICdtYWlsaW5hYm94LmVtYWlsJywKICAgICdwa2kuZ29vZycsCiAgICAndGVsZWdyYW0ub3JnJywKICAgICdkZWVyZS5jb20nLAogICAgJ2Ruc21hZGVlYXN5LmNvbScsCiAgICAnbGF1bmNoZGFya2x5LmNvbScsCiAgICAndmsucnUnLAogICAgJ2lzc3V1LmNvbScsCiAgICAnY3JwdC5ydScsCiAgICAneWFuZGV4LmNvbScsCiAgICAnbmdlbml4Lm5ldCcsCiAgICAndmtvbnRha3RlLnJ1JywKICAgICdjbmJjLmNvbScsCiAgICAnZHVja2R1Y2tnby5jb20nLAogICAgJ21pa3JvdGlrLmNvbScsCiAgICAnZmVhdHVyZWFzc2V0cy5vcmcnLAogICAgJ2V5ZTQuY24nLAogICAgJ2FyeGl2Lm9yZycsCiAgICAnYmV5b25kd2lja2VkbWFwcGluZy5vcmcnLAogICAgJ3J1bi5hcHAnLAogICAgJ29wZW54Lm5ldCcsCiAgICAndGltZS5jb20nLAogICAgJ3RlY2hjcnVuY2guY29tJywKICAgICdzaGFyZS5nb29nbGUnLAogICAgJ2VscGFpcy5jb20nLAogICAgJ2cuY28nLAogICAgJ3F1YW50c2VydmUuY29tJywKICAgICdpZDUtc3luYy5jb20nLAogICAgJ2NyZWF0aXZlY2RuLmNvbScsCiAgICAnYXN1cy5jb20nLAogICAgJ2JhbmRjYW1wLmNvbScsCiAgICAnc2hvcGVlLmNvLmlkJywKICAgICdhZGZvcm0ubmV0JywKICAgICdpcGluZm8uaW8nLAogICAgJ3Nob3BlZS5jb20uYnInLAogICAgJ2RhdW0ubmV0JywKICAgICdhbGxlZ3JvLnBsJywKICAgICdteXNwYWNlLmNvbScsCiAgICAnb25ldGFnLXN5cy5jb20nLAogICAgJ2Zic2J4LmNvbScsCiAgICAnZXUtMS1pZDUtc3luYy5jb20nLAogICAgJ3B4LWNsb3VkLm5ldCcsCiAgICAndHN5bmRpY2F0ZS5jb20nLAogICAgJ3RhaWxzY2FsZS5jb20nLAogICAgJ3NvZmFzY29yZS5jb20nLAogICAgJ2RvY29tby5uZS5qcCcsCiAgICAnbnlwb3N0LmNvbScsCiAgICAnYXBwLWFuYWx5dGljcy1zZXJ2aWNlcy1hdHQuY29tJywKICAgICdhcy5jb20nLAogICAgJ21hZ25pZmljLmNvbScsCiAgICAnYWRibG9ja3BsdXMub3JnJywKICAgICdsd3NkbnMuY29tJywKICAgICd5YW5kZXgua3onLAogICAgJ3lhbmRleC5jb20udHInLAogICAgJ2ZiLm1lJywKICAgICdjc3BzZXJ2ZXIubmV0JywKICAgICd4aGFtc3RlcjE5LmNvbScsCiAgICAneGhhbXN0ZXIyLmNvbScsCiAgICAndm5leHByZXNzLm5ldCcsCiAgICAnc2FmZXR5Lmdvb2dsZScsCiAgICAneGhhY2Nlc3MuY29tJywKICAgICdiNzUxMC5jb20nLAogICAgJ2xpY2hlc3Mub3JnJywKICAgICd4aG9wZW4uY29tJywKICAgICd4aG5hbWUuY29tJywKICAgICdzYXBvLnB0JywKICAgICdkaXZhci5pcicsCiAgICAna2VybmVsLm9yZycsCiAgICAnbGFicy5nb29nbGUnLAogICAgJ3RhcGFkLmNvbScsCiAgICAnanVzdGRpYWwuY29tJywKICAgICdzaG9wZWUuY29tLm15JywKICAgICdlZG5hLnJ1JywKICAgICd0aGlzdmlkLmNvbScsCiAgICAneGhzcG90LmNvbScsCiAgICAnaGl0b21pLmxhJywKICAgICd4aHNvY2lhbC5jb20nLAogICAgJ3J1bGUzNHZpZGVvLmNvbScsCiAgICAnbWFuZ2FidWZmLnJ1JywKICAgICdzaW1wY2l0eS5jcicsCiAgICAncGFya2xvZ2ljLmNvbScsCiAgICAnZWtzdHJhYmxhZGV0LmRrJywKICAgICcxYy5ydScsCiAgICAnamNwaGkuY29tJywKICAgICdha2lzbWV0LmNvbScsCiAgICAndGhleGgubGl2ZScsCiAgICAncG9ybm9ib3JzaGNoLmNvbScsCiAgICAnZmVkb3JhcHJvamVjdC5vcmcnLAogICAgJzZvcG8uY29tJywKICAgICdjb250ZXh0d2ViLmNvbScsCiAgICAnbWVjaGFjb21pYy5qcCcsCiAgICAnczhleS5jb20nLAogICAgJ3Npbm9wdGlrLnVhJywKICAgICdya3YxLmNvbScsCiAgICAnYWsyeXkuY29tJywKICAgICduaWNrZmluZGVyLmNvbScsCiAgICAnc2l0ZS5jb20nLAogICAgJ2ltZ3NyYy5ydScsCiAgICAnYmxhY2tydXNzaWEub25saW5lJywKICAgICdhbnNlcy5nb2IuYXInLAogICAgJzMzYXBrLmNvbScsCiAgICAnaG90eHYuY29tJywKICAgICdwYWNrenkuY29tJywKICAgICd2bnNleHRvcDEuY29tJywKICAgICd4eHh2aWRlb3NpbmQuY29tJywKICAgICdzdGFzZXJhaW50di5jb20nLAogICAgJ3lvdXItc2VydmVyLmRlJywKICAgICdra3N0b3JpZXMuY29tJywKICAgICdkYW50cmkuY29tLnZuJywKICAgICdtYWduaXQucnUnLAogICAgJ2hoLnJ1JywKICAgICdtZXJjYWRvbGlicmUuY29tJywKICAgICdiYWRvby5jb20nLAogICAgJ2ZpcnN0dmRzLnJ1JywKICAgICdqaW5vLnJ1JywKICAgICduczFwLm5ldCcsCiAgICAnZmIud2F0Y2gnLAogICAgJ2Z1bGx4aC5jb20nLAogICAgJ25wY2kub3JnLmluJywKICAgICd5aW1nLmNvbScsCiAgICAnZ2FtYS5pcicsCiAgICAnbGltby5tZWRpYScsCiAgICAnOTlyZGQuY29tJywKICAgICdhdGNwdWxzYS5zdG9yZScsCikKCmRlZiB2YWxpZGF0ZV9zbmlfcG9vbChkb2MsIG1heF9hZ2U9Nyo4NjQwMCk6CiAgICBpZiBub3QgaXNpbnN0YW5jZShkb2MsZGljdCkgb3IgZG9jLmdldCgnc2NoZW1hJykhPTE6cmFpc2UgVmFsdWVFcnJvcignU05JIOa4heWNleagvOW8j+aXoOaViCcpCiAgICBzdGFtcD1kb2MuZ2V0KCdnZW5lcmF0ZWRfYXQnKQogICAgaWYgaXNpbnN0YW5jZShzdGFtcCxib29sKSBvciBub3QgaXNpbnN0YW5jZShzdGFtcCwoaW50LGZsb2F0KSkgb3Igbm90IDAgPD0gdGltZS50aW1lKCktc3RhbXAgPD0gbWF4X2FnZToKICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCdTTkkg5riF5Y2V6L+H5pyf5oiW5pe26Ze05peg5pWIJykKICAgIG5hbWVzPWRvYy5nZXQoJ2RvbWFpbnMnKQogICAgaWYgbm90IGlzaW5zdGFuY2UobmFtZXMsbGlzdCkgb3Igbm90IDEgPD0gbGVuKG5hbWVzKSA8PSA0MDk2OnJhaXNlIFZhbHVlRXJyb3IoJ1NOSSDlgJnpgInmlbDph4/ml6DmlYgnKQogICAgZm9yIG5hbWUgaW4gbmFtZXM6CiAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UobmFtZSxzdHIpIG9yIGxlbihuYW1lKT4yNTMgb3IgJy4nIG5vdCBpbiBuYW1lIG9yIGFueShub3QgcmUuZnVsbG1hdGNoKHInW2EtejAtOV0oPzpbYS16MC05LV17MCw2MX1bYS16MC05XSk/JyxsYWJlbCkgZm9yIGxhYmVsIGluIG5hbWUuc3BsaXQoJy4nKSk6CiAgICAgICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoJ1NOSSDlgJnpgInln5/lkI3ml6DmlYgnKQogICAgcmV0dXJuIGxpc3QoZGljdC5mcm9ta2V5cyhuYW1lcykpCgoKZGVmIGxvYWRfc25pX3Bvb2woYXJncyxzdGF0ZSk6CiAgICAjIFN0YWJsZSBkYXRhIGVuZHBvaW50IG5leHQgdG8gdGhlIG1hbmlmZXN0LiBOZXZlciBmb2xsb3dzIHJlZGlyZWN0cyBvciBzZW5kcwogICAgIyBkb3dubG9hZCBjcmVkZW50aWFscyB0byBhIGRpZmZlcmVudCBvcmlnaW47IG5vIHJlbW90ZSBjb2RlIGlzIGV4ZWN1dGVkLgogICAgcmVsZWFzZT1zdGF0ZS5nZXQoJ3JlbGVhc2VfbWFuaWZlc3QnKQogICAgaWYgbm90IHJlbGVhc2U6CiAgICAgICAgcHJpbnQoJ+acqumFjee9ruWPkeW4g+a4heWNle+8jOS9v+eUqOWGhee9riBTTkkg5bqU5oCl5YCZ6YCJ77yb5LuN6ZyA5pys5py6IFRMUyDpqozor4EnLGZsdXNoPVRydWUpCiAgICAgICAgcmV0dXJuIGxpc3QoU05JX1BPT0wpCiAgICB1cmw9dXJsbGliLnBhcnNlLnVybGpvaW4ocmVsZWFzZSwnc25pLXBvb2wuanNvbicpCiAgICBjYWNoZT1ST09ULydzbmktcG9vbC1jYWNoZS5qc29uJwogICAgcHJldmlvdXM9Tm9uZQogICAgdHJ5OgogICAgICAgIHNhdmVkPWpzb24ubG9hZHMoY2FjaGUucmVhZF90ZXh0KCkpCiAgICAgICAgaWYgc2F2ZWQuZ2V0KCdzb3VyY2UnKT09dXJsOgogICAgICAgICAgICB2YWxpZGF0ZV9zbmlfcG9vbChzYXZlZFsncG9vbCddKTtwcmV2aW91cz1zYXZlZFsncG9vbCddCiAgICBleGNlcHQgKE9TRXJyb3IsVmFsdWVFcnJvcixLZXlFcnJvcixUeXBlRXJyb3IpOnBhc3MKICAgIHRyeToKICAgICAgICBhdXRoPWRvd25sb2FkX2F1dGgoYXJncyx1cmwscmVsZWFzZSkKICAgICAgICBkb2M9cmVxdWVzdCh1cmwsYXV0aCkgaWYgYXV0aCBlbHNlIHJlcXVlc3QodXJsKQogICAgICAgIG5hbWVzPXZhbGlkYXRlX3NuaV9wb29sKGRvYykKICAgICAgICBpZiBwcmV2aW91cyBhbmQgZG9jWydnZW5lcmF0ZWRfYXQnXSA8IHByZXZpb3VzWydnZW5lcmF0ZWRfYXQnXToKICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJvcignU05JIOa4heWNleeJiOacrOWAkumAgCcpCiAgICAgICAgYXRvbWljKGNhY2hlLGpzb24uZHVtcHMoeydzb3VyY2UnOnVybCwncG9vbCc6ZG9jfSkpCiAgICAgICAgcHJpbnQoJ1NOSSDlrp7ml7bmuIXljZXvvJonK3N0cihsZW4obmFtZXMpKSsnIOS4quWAmemAie+8jOabtOaWsOS6jiAnK3RpbWUuc3RyZnRpbWUoJyVZLSVtLSVkICVIOiVNOiVTIFVUQycsdGltZS5nbXRpbWUoZG9jWydnZW5lcmF0ZWRfYXQnXSkpLGZsdXNoPVRydWUpCiAgICAgICAgcmV0dXJuIG5hbWVzCiAgICBleGNlcHQgKFJ1bnRpbWVFcnJvcixWYWx1ZUVycm9yLE9TRXJyb3IsVHlwZUVycm9yKToKICAgICAgICBpZiBwcmV2aW91czoKICAgICAgICAgICAgcHJpbnQoJ1NOSSDlnKjnur/mm7TmlrDlpLHotKXvvIzkvb/nlKjmnIDov5HmnInmlYjnvJPlrZjvvJvku43pnIDmnKzmnLogVExTIOmqjOivgScsZmx1c2g9VHJ1ZSkKICAgICAgICAgICAgcmV0dXJuIHZhbGlkYXRlX3NuaV9wb29sKHByZXZpb3VzKQogICAgICAgIHByaW50KCdTTkkg5Zyo57q/5pu05paw5aSx6LSl5LiU5peg5pyJ5pWI57yT5a2Y77yM5L2/55So5YaF572u5bqU5oCl5YCZ6YCJ77yb5LuN6ZyA5pys5py6IFRMUyDpqozor4EnLGZsdXNoPVRydWUpCiAgICAgICAgcmV0dXJuIGxpc3QoU05JX1BPT0wpCgoKZGVmIHNuaV91c2FnZShub2Rlcyk6CiAgICBjb3VudHM9Q291bnRlcigpCiAgICBmb3Igbm9kZSBpbiBub2RlczoKICAgICAgICB0bHM9bm9kZS5nZXQoJ3Rsc19zZXR0aW5ncycpCiAgICAgICAgbmFtZXM9e25vZGUuZ2V0KCdzZXJ2ZXJfbmFtZScpLHRscy5nZXQoJ3NlcnZlcl9uYW1lJykgaWYgaXNpbnN0YW5jZSh0bHMsZGljdCkgZWxzZSBOb25lfQogICAgICAgICMgVGhlIHNhbWUgZG9tYWluIGluIGJvdGggZmllbGRzIG9mIG9uZSByb3cgY291bnRzIG9uY2U7IGhpZGRlbiByb3dzIGNvdW50IHRvby4KICAgICAgICBjb3VudHMudXBkYXRlKHtuYW1lLmxvd2VyKCkucnN0cmlwKCcuJykgZm9yIG5hbWUgaW4gbmFtZXMgaWYgaXNpbnN0YW5jZShuYW1lLHN0cikgYW5kIG5hbWV9KQogICAgcmV0dXJuIGNvdW50cwoKCmRlZiBjaG9vc2Vfc25pKHVzZWQsdGxzMTM9RmFsc2UscG9vbD1Ob25lKToKICAgIGNvdW50cz1Db3VudGVyKHVzZWQpCiAgICAjIFNodWZmbGUgdGllcywgdGhlbiBwcmVmZXIgdW51c2VkIC8gbGVhc3QtdXNlZCBkb21haW5zLiBSZXVzZSBzdGlsbCByZXF1aXJlcyBUTFMuCiAgICBwb29sPVNOSV9QT09MIGlmIHBvb2wgaXMgTm9uZSBlbHNlIHBvb2wKICAgIGNhbmRpZGF0ZXM9c2VjcmV0cy5TeXN0ZW1SYW5kb20oKS5zYW1wbGUocG9vbCxsZW4ocG9vbCkpCiAgICBjYW5kaWRhdGVzLnNvcnQoa2V5PWxhbWJkYSBob3N0OmNvdW50c1tob3N0XSkKICAgIGZhaWx1cmVzPUNvdW50ZXIoKQogICAgZm9yIGhvc3QgaW4gY2FuZGlkYXRlczoKICAgICAgICB0cnk6CiAgICAgICAgICAgIHdpdGggc29ja2V0LmNyZWF0ZV9jb25uZWN0aW9uKChob3N0LDQ0MyksdGltZW91dD01KSBhcyBzb2NrOgogICAgICAgICAgICAgICAgd2l0aCBzc2wuY3JlYXRlX2RlZmF1bHRfY29udGV4dCgpLndyYXBfc29ja2V0KHNvY2ssc2VydmVyX2hvc3RuYW1lPWhvc3QpIGFzIHRsczoKICAgICAgICAgICAgICAgICAgICB2ZXJzaW9uPXRscy52ZXJzaW9uKCkKICAgICAgICAgICAgICAgICAgICBpZiBub3QgdmVyc2lvbiBvciAodGxzMTMgYW5kIHZlcnNpb24hPSdUTFN2MS4zJyk6CiAgICAgICAgICAgICAgICAgICAgICAgIGZhaWx1cmVzWydUTFPniYjmnKzkuI3mu6HotrPopoHmsYInXSs9MQogICAgICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICAgICAgICAgIGlmIGNvdW50c1tob3N0XToKICAgICAgICAgICAgICAgICAgICAgICAgcHJpbnQoJ+iHquWKqCBTTkkg5aSN55So77yaJytob3N0KyfvvIjpnaLmnb8v5pys5qyh5bey5L2/55SoICcrc3RyKGNvdW50c1tob3N0XSkrJyDmrKHvvIxUTFMg6aqM6K+B6YCa6L+H77yJJyxmbHVzaD1UcnVlKQogICAgICAgICAgICAgICAgICAgIHJldHVybiBob3N0CiAgICAgICAgZXhjZXB0IHNzbC5TU0xDZXJ0VmVyaWZpY2F0aW9uRXJyb3I6ZmFpbHVyZXNbJ+ivgeS5pumqjOivgeWksei0pSddKz0xCiAgICAgICAgZXhjZXB0IHNzbC5TU0xFcnJvcjpmYWlsdXJlc1snVExT5o+h5omL5aSx6LSlJ10rPTEKICAgICAgICBleGNlcHQgT1NFcnJvcjpmYWlsdXJlc1snRE5TL+i/nuaOpeWksei0pSddKz0xCiAgICBkZXRhaWw9J+OAgScuam9pbihrKyc9JytzdHIodikgZm9yIGssdiBpbiBmYWlsdXJlcy5pdGVtcygpKQogICAgcmFpc2UgUnVudGltZUVycm9yKCfoh6rliqggU05JIOa1i+ivleayoeaciemAmui/h++8iOW3sua1i+ivlSAnK3N0cihsZW4oY2FuZGlkYXRlcykpKycg5Liq5YCZ6YCJ77yM5YWB6K645aSN55So77ybJytkZXRhaWwrJ++8ie+8jOivt+ajgOafpee9kee7nC/ns7vnu5/ml7bpl7QvQ0HvvIzmiJbpgJrov4cgLS1zbmkg5oyH5a6a5bey6aqM6K+B5Z+f5ZCNJykKCmRlZiBkZXBlbmRlbmN5X2NoZWNrKCk6CiAgICBpZiBub3QgUGF0aCgnL3J1bi9zeXN0ZW1kL3N5c3RlbScpLmlzX2RpcigpOnJhaXNlIFJ1bnRpbWVFcnJvcign6ZyA6KaB5L2/55SoIHN5c3RlbWQg55qE5pyN5Yqh5ZmoJykKICAgIG5lZWRlZD0oJ25mdCcsJ3NzJywndGMnLCdzeXNjdGwnLCdtb2Rwcm9iZScsJ3VzZXJhZGQnLCdydW51c2VyJykKICAgIGlmIGFsbChzaHV0aWwud2hpY2goeCkgZm9yIHggaW4gbmVlZGVkKTpyZXR1cm4KICAgIHByaW50KCfmraPlnKjlronoo4XnvLrlsJHnmoTov5DooYzkvp3otZbigKYnLGZsdXNoPVRydWUpCiAgICBpZiBzaHV0aWwud2hpY2goJ2FwdC1nZXQnKToKICAgICAgICBydW4oJ2FwdC1nZXQnLCd1cGRhdGUnLCctcXEnKQogICAgICAgIHJ1bignZW52JywnREVCSUFOX0ZST05URU5EPW5vbmludGVyYWN0aXZlJywnYXB0LWdldCcsJ2luc3RhbGwnLCcteScsJy0tbm8taW5zdGFsbC1yZWNvbW1lbmRzJywnbmZ0YWJsZXMnLCdpcHJvdXRlMicsJ3Byb2NwcycsJ2ttb2QnLCdwYXNzd2QnLCd1dGlsLWxpbnV4JywnY2EtY2VydGlmaWNhdGVzJykKICAgIGVsaWYgc2h1dGlsLndoaWNoKCdkbmYnKToKICAgICAgICBydW4oJ2RuZicsJ2luc3RhbGwnLCcteScsJ25mdGFibGVzJywnaXByb3V0ZScsJ3Byb2Nwcy1uZycsJ2ttb2QnLCdzaGFkb3ctdXRpbHMnLCd1dGlsLWxpbnV4JywnY2EtY2VydGlmaWNhdGVzJykKICAgIGVsc2U6cmFpc2UgUnVudGltZUVycm9yKCfml6Dms5Xlronoo4Xkvp3otZbvvJrmnKrmib7liLAgYXB0LWdldCDmiJYgZG5mJykKCmRlZiBoYXNfYWRkaXRpb25hbF9pcF9pbnN0YW5jZXMoKToKICAgIHBhdGg9Uk9PVC8naXAtcG9vbC5qc29uJwogICAgaWYgcGF0aC5leGlzdHMoKToKICAgICAgICBkYXRhPWpzb24ubG9hZHMocGF0aC5yZWFkX3RleHQoKSkKICAgICAgICBpZiBhbnkoZS5nZXQoJ3VuaXQnKSBvciBlLmdldCgnc2xvdCcpIGZvciBlIGluIGRhdGEuZ2V0KCdhZGRyZXNzZXMnLHt9KS52YWx1ZXMoKSk6cmV0dXJuIFRydWUKICAgIHJldHVybiBhbnkocC5uYW1lIT0nd2hhbGVub2RlLWlwLXBvb2wuc2VydmljZScgZm9yIHAgaW4gUGF0aCgnL2V0Yy9zeXN0ZW1kL3N5c3RlbScpLmdsb2IoJ3doYWxlbm9kZS1pcC0qLnNlcnZpY2UnKSkKCgpkZWYgcm9sbGJhY2soc3RhdGUpOgogICAgaWYgaGFzX2FkZGl0aW9uYWxfaXBfaW5zdGFuY2VzKCk6cmFpc2UgUnVudGltZUVycm9yKCflrZjlnKjpmYTliqAgSVAg5a6e5L6L77yM5LiN6IO95Zue5rua5YWx55So5Ye65Y+j6KeE5YiZ5oiW5Y6f5pyN5Yqh77yb6K+35YWI6YCQ5a6e5L6L5aSE55CGJykKICAgIGlmIG5vdCBzdGF0ZS5nZXQoJ293bnNfc2VydmljZScpIGFuZCBub3Qgc3RhdGUuZ2V0KCdvd25zX2VncmVzcycpOnJhaXNlIFJ1bnRpbWVFcnJvcign5pys5Lu75Yqh5bCa5pyq5L+u5pS55pyN5Yqh5oiW57O757uf5Y+C5pWw77yM5peg6ZyA5Zue5ruaJykKICAgIHJ1bignc3lzdGVtY3RsJywnZGlzYWJsZScsJy0tbm93Jywnd2hhbGVub2RlLnNlcnZpY2UnLGNoZWNrPUZhbHNlKQogICAgcnVuKCdzeXN0ZW1jdGwnLCdkaXNhYmxlJywnLS1ub3cnLCd3aGFsZW5vZGUtZWdyZXNzLnNlcnZpY2UnLGNoZWNrPUZhbHNlKQogICAgaWYgc3RhdGUuZ2V0KCdvd25zX2VncmVzcycpOnJ1bignbmZ0JywnZGVsZXRlJywndGFibGUnLCdpbmV0Jywnd2hhbGVub2RlX2VncmVzcycsY2hlY2s9RmFsc2UpCiAgICByZXN0b3JlX3NvdXJjZV9wb3J0cyhzdGF0ZSkKICAgIHBhdGg9Uk9PVC8nc3lzY3RsLWJlZm9yZS5qc29uJwogICAgaWYgcGF0aC5leGlzdHMoKToKICAgICAgICBmb3Iga2V5LHZhbHVlIGluIGpzb24ubG9hZHMocGF0aC5yZWFkX3RleHQoKSkuaXRlbXMoKTpydW4oJ3N5c2N0bCcsJy13JyxrZXkrJz0nK3N0cih2YWx1ZSkpCiAgICBmb3IgcGF0aCBpbiBbJy9ldGMvc3lzdGVtZC9zeXN0ZW0vd2hhbGVub2RlLnNlcnZpY2UnLCcvZXRjL3N5c3RlbWQvc3lzdGVtL3doYWxlbm9kZS1lZ3Jlc3Muc2VydmljZScsJy9ldGMvd2hhbGVub2RlLWVncmVzcy5uZnQnLCcvZXRjL3N5c2N0bC5kLzkwLXdoYWxlbm9kZS5jb25mJ106CiAgICAgICAgUGF0aChwYXRoKS51bmxpbmsobWlzc2luZ19vaz1UcnVlKQogICAgcnVuKCdzeXN0ZW1jdGwnLCdkYWVtb24tcmVsb2FkJykKICAgIHN0YXRlWydwaGFzZSddPSdyb2xsZWRfYmFjayc7YXRvbWljKFJPT1QvJ3N0YXRlLmpzb24nLGpzb24uZHVtcHMoc3RhdGUsZW5zdXJlX2FzY2lpPUZhbHNlLGluZGVudD0yKSkKICAgIHByaW50KCflt7LlgZzmraLmnKzku7vliqHmnI3liqHjgIHnp7vpmaTmnKzku7vliqHop4TliJnlubbmgaLlpI3ns7vnu5/lj4LmlbDjgILphY3nva7lkozpmpDol4/pnaLmnb/oioLngrnkv53nlZnvvIzkvr/kuo7moLjmn6Xlj4rnu63ot5HjgIInKQoKZGVmIGFjdGl2ZSh1bml0KToKICAgIHJldHVybiBydW4oJ3N5c3RlbWN0bCcsJ2lzLWFjdGl2ZScsJy0tcXVpZXQnLHVuaXQsY2hlY2s9RmFsc2UpLnJldHVybmNvZGU9PTAKCmRlZiBleHBvcnRfcmVwb3J0KHBhdGgscmVwb3J0KToKICAgICMgTmV2ZXIgb3ZlcndyaXRlIGNvbmZpZywgYW5vdGhlciByZXBvcnQgb3IgYSBzeW1saW5rIHdpdGggYSBkaWFnbm9zdGljIHJlcG9ydC4KICAgIHJhdz1qc29uLmR1bXBzKHJlcG9ydCxlbnN1cmVfYXNjaWk9RmFsc2UsaW5kZW50PTIpLmVuY29kZSgndXRmLTgnKQogICAgdHJ5OmZkPW9zLm9wZW4ocGF0aCxvcy5PX1dST05MWXxvcy5PX0NSRUFUfG9zLk9fRVhDTHxvcy5PX05PRk9MTE9XLDBvNjAwKQogICAgZXhjZXB0IEZpbGVFeGlzdHNFcnJvcjpyYWlzZSBWYWx1ZUVycm9yKCfmiqXlkYrmlofku7blt7LlrZjlnKjvvIzor7fkvb/nlKjmlrDnmoTmlofku7blkI3vvJvmnKropobnm5blt7LmnInlhoXlrrknKSBmcm9tIE5vbmUKICAgIGV4Y2VwdCBPU0Vycm9yOnJhaXNlIFJ1bnRpbWVFcnJvcign5peg5rOV5Yib5bu65oql5ZGK77yM6K+35qOA5p+l55uu5qCH55uu5b2V5Y+K5YaZ5YWl5p2D6ZmQJykgZnJvbSBOb25lCiAgICB3aXRoIG9zLmZkb3BlbihmZCwnd2InKSBhcyBmOgogICAgICAgIGYud3JpdGUocmF3KTtmLmZsdXNoKCk7b3MuZnN5bmMoZi5maWxlbm8oKSkKCmRlZiBkaWFnbm9zZShzdGF0ZSk6CiAgICBjaGVja3M9W10KICAgIGRlZiBjaGVjayhrZXksbGFiZWwsZm4pOgogICAgICAgIHRyeTpwYXNzZWQ9Ym9vbChmbigpKQogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246cGFzc2VkPUZhbHNlCiAgICAgICAgY2hlY2tzLmFwcGVuZCh7J2tleSc6a2V5LCdsYWJlbCc6bGFiZWwsJ3Bhc3NlZCc6cGFzc2VkfSkKICAgIGNoZWNrKCdzdGF0ZScsJ+WtmOWcqOacrOacuuWuieijheS7u+WKoScsbGFtYmRhOmJvb2woc3RhdGUuZ2V0KCdpZHMnKSkpCiAgICBjaGVjaygnYmFja2VuZF9hY3RpdmUnLCdXaGFsZU5vZGUg5pyN5Yqh6L+Q6KGMJyxsYW1iZGE6YWN0aXZlKCd3aGFsZW5vZGUuc2VydmljZScpKQogICAgZGVmIHJ1bm5pbmdfaGFzaCgpOgogICAgICAgIHBpZD1ydW4oJ3N5c3RlbWN0bCcsJ3Nob3cnLCd3aGFsZW5vZGUuc2VydmljZScsJy0tcHJvcGVydHk9TWFpblBJRCcsJy0tdmFsdWUnKS5zdGRvdXQuc3RyaXAoKQogICAgICAgIGlmIG5vdCBwaWQuaXNkaWdpdCgpIG9yIGludChwaWQpPT0wOnJldHVybiBGYWxzZQogICAgICAgIHJldHVybiBoYXNobGliLnNoYTI1NihQYXRoKCcvcHJvYy8nK3BpZCsnL2V4ZScpLnJlYWRfYnl0ZXMoKSkuaGV4ZGlnZXN0KCk9PXN0YXRlLmdldCgnYmluYXJ5X3NoYTI1NicpCiAgICBjaGVjaygncnVubmluZ19oYXNoJywn6L+Q6KGM5paH5Lu2IFNIQTI1NiDkuI7lt7LmoKHpqozliLblk4HkuIDoh7QnLHJ1bm5pbmdfaGFzaCkKICAgIGRlZiBzZXJ2aWNlX3VzZXIoKToKICAgICAgICByZXR1cm4gcnVuKCdzeXN0ZW1jdGwnLCdzaG93Jywnd2hhbGVub2RlLnNlcnZpY2UnLCctLXByb3BlcnR5PVVzZXInLCctLXZhbHVlJykuc3Rkb3V0LnN0cmlwKCk9PSd3aGFsZW5vZGUnCiAgICBjaGVjaygnc2VydmljZV91c2VyJywn5ZCO56uv5L2/55So5LiT55So6Z2eIHJvb3Qg55So5oi3JyxzZXJ2aWNlX3VzZXIpCiAgICBkZWYgcHJpdmF0ZV9jb25maWcoKToKICAgICAgICB1aWQ9cHdkLmdldHB3bmFtKCd3aGFsZW5vZGUnKS5wd191aWQKICAgICAgICBmaWxlcz1bKENPTkYsMG83MDApLChDT05GLydjb25maWcuanNvbicsMG82MDApLChDT05GLydzaW5nX29yaWdpbmFsLmpzb24nLDBvNjAwKV0KICAgICAgICByZXR1cm4gYWxsKG5vdCBwLmlzX3N5bWxpbmsoKSBhbmQgcC5zdGF0KCkuc3RfdWlkPT11aWQgYW5kIHN0YXQuU19JTU9ERShwLnN0YXQoKS5zdF9tb2RlKT09bW9kZSBmb3IgcCxtb2RlIGluIGZpbGVzKQogICAgY2hlY2soJ2NvbmZpZ19wZXJtaXNzaW9ucycsJ+WQjuerr+mFjee9ruWxnuS4u+WPiuengeWvhuadg+mZkOato+ehricscHJpdmF0ZV9jb25maWcpCiAgICBkZWYgY29uZmlnX2JpbmRpbmcoKToKICAgICAgICBub2Rlcz1qc29uLmxvYWRzKChDT05GLydjb25maWcuanNvbicpLnJlYWRfdGV4dCgpKS5nZXQoJ05vZGVzJyxbXSkKICAgICAgICBleHBlY3RlZD17KCdoeXN0ZXJpYTInIGlmIHA9PSdoeTInIGVsc2UgcCxpbnQobikpIGZvciBwLG4gaW4gc3RhdGUuZ2V0KCdpZHMnLHt9KS5pdGVtcygpfQogICAgICAgIHJldHVybiBib29sKGV4cGVjdGVkKSBhbmQgbGVuKG5vZGVzKT09bGVuKGV4cGVjdGVkKSBhbmQgeyhuLmdldCgnTm9kZVR5cGUnKSxuLmdldCgnTm9kZUlEJykpIGZvciBuIGluIG5vZGVzfT09ZXhwZWN0ZWQgYW5kIGFsbChuLmdldCgnQXBpSG9zdCcpPT1zdGF0ZS5nZXQoJ2FwaV91cmwnKSBhbmQgbi5nZXQoJ0FwaUtleScpIGZvciBuIGluIG5vZGVzKQogICAgY2hlY2soJ2NvbmZpZ19iaW5kaW5nJywn6YWN572u5Lit55qE6Z2i5p2/5LiO6IqC54K5IElEIOWvueW6lOW9k+WJjeS7u+WKoScsY29uZmlnX2JpbmRpbmcpCiAgICBjaGVjaygnZWdyZXNzX2FjdGl2ZScsJ0lQdjYg5Ye65Y+j6KeE5YiZ5pyN5Yqh6L+Q6KGMJyxsYW1iZGE6YWN0aXZlKCd3aGFsZW5vZGUtZWdyZXNzLnNlcnZpY2UnKSkKICAgIGRlZiBpcHY2X3J1bGUoKToKICAgICAgICB1aWQ9cHdkLmdldHB3bmFtKCd3aGFsZW5vZGUnKS5wd191aWQKICAgICAgICBkb2N1bWVudD1qc29uLmxvYWRzKHJ1bignbmZ0JywnLWonLCdsaXN0JywndGFibGUnLCdpbmV0Jywnd2hhbGVub2RlX2VncmVzcycpLnN0ZG91dCkKICAgICAgICBlbnRyaWVzPWRvY3VtZW50LmdldCgnbmZ0YWJsZXMnLFtdKQogICAgICAgIGNoYWlucz1beFsnY2hhaW4nXSBmb3IgeCBpbiBlbnRyaWVzIGlmICdjaGFpbicgaW4geF0KICAgICAgICBpZiBub3QgYW55KGMuZ2V0KCduYW1lJyk9PSdvdXRwdXQnIGFuZCBjLmdldCgnaG9vaycpPT0nb3V0cHV0JyBhbmQgYy5nZXQoJ3R5cGUnKT09J2ZpbHRlcicgZm9yIGMgaW4gY2hhaW5zKTpyZXR1cm4gRmFsc2UKICAgICAgICBydWxlcz1beFsncnVsZSddIGZvciB4IGluIGVudHJpZXMgaWYgJ3J1bGUnIGluIHggYW5kIHhbJ3J1bGUnXS5nZXQoJ2NoYWluJyk9PSdvdXRwdXQnXQogICAgICAgICMgUmVxdWlyZSB0aGUgZmlyc3QgcnVsZSB0byBiZSBvdXIgVUlEICsgSVB2NiByZWplY3Q7IGFuIGVhcmxpZXIgYWNjZXB0IGNvdWxkIGJ5cGFzcyBpdC4KICAgICAgICBpZiBub3QgcnVsZXM6cmV0dXJuIEZhbHNlCiAgICAgICAgZXhwcj1ydWxlc1swXS5nZXQoJ2V4cHInLFtdKQogICAgICAgIG1hdGNoZXM9W2VbJ21hdGNoJ10gZm9yIGUgaW4gZXhwciBpZiAnbWF0Y2gnIGluIGVdCiAgICAgICAgaWYgbGVuKG1hdGNoZXMpIT0yIG9yIGFueShub3QgKCdtYXRjaCcgaW4gZSBvciAnY291bnRlcicgaW4gZSBvciAncmVqZWN0JyBpbiBlKSBmb3IgZSBpbiBleHByKTpyZXR1cm4gRmFsc2UKICAgICAgICBkZWYgbWF0Y2hlc19tZXRhKGtleSx2YWx1ZXMpOgogICAgICAgICAgICByZXR1cm4gYW55KG0uZ2V0KCdvcCcpPT0nPT0nIGFuZCBtLmdldCgnbGVmdCcpPT17J21ldGEnOnsna2V5JzprZXl9fSBhbmQgbS5nZXQoJ3JpZ2h0JykgaW4gdmFsdWVzIGZvciBtIGluIG1hdGNoZXMpCiAgICAgICAgcmV0dXJuIG1hdGNoZXNfbWV0YSgnc2t1aWQnLCh1aWQsc3RyKHVpZCksJ3doYWxlbm9kZScpKSBhbmQgbWF0Y2hlc19tZXRhKCduZnByb3RvJywoJ2lwdjYnLDEwKSkgYW5kIGFueSgncmVqZWN0JyBpbiBlIGZvciBlIGluIGV4cHIpCiAgICBjaGVjaygnaXB2Nl9ydWxlJywn6aaW5p2h5Ye65Y+j6KeE5YiZ5ouS57ud5LiT55So55So5oi355qEIElQdjYg5rWB6YePJyxpcHY2X3J1bGUpCiAgICBmb3IgcHJvdG8gaW4gc3RhdGUuZ2V0KCdwcm90b2NvbHMnLFtdKToKICAgICAgICBpZiBwcm90byBub3QgaW4gUFJPVE9DT0xTOgogICAgICAgICAgICBjaGVjaygncHJvdG9jb2xfdW5rbm93bicsJ+S7u+WKoeS4reWtmOWcqOacquefpeWNj+iuricsbGFtYmRhOkZhbHNlKTtjb250aW51ZQogICAgICAgIHNvY2s9Jy1sdW4nIGlmIHByb3RvPT0naHkyJyBlbHNlICctbHRuJwogICAgICAgIGNoZWNrKCdsaXN0ZW5fJytwcm90byxwcm90by51cHBlcigpKycg5Y2P6K6u56uv5Y+j5bey55uR5ZCsJyxsYW1iZGEgc29jaz1zb2NrLHByb3RvPXByb3RvOmxlbihydW4oJ3NzJyxzb2NrLCdzcG9ydCA9IDonK3N0cihQUk9UT0NPTFNbcHJvdG9dWzFdKSkuc3Rkb3V0LnNwbGl0bGluZXMoKSk+MSkKICAgIHJldHVybiB7J3NjaGVtYSc6MSwnZ2VuZXJhdGVkX2F0JzppbnQodGltZS50aW1lKCkpLCdzY29wZSc6J2xvY2FsX29ubHknLCdwYXNzZWQnOmJvb2woY2hlY2tzKSBhbmQgYWxsKHhbJ3Bhc3NlZCddIGZvciB4IGluIGNoZWNrcyksCiAgICAgICAgICAgICdub2RlJzp7azpzdGF0ZS5nZXQoaykgZm9yIGsgaW4gKCdob3N0JywnbmFtZScsJ3Byb3RvY29scycsJ2lkcycsJ3BoYXNlJywncmVzb3VyY2VzJywnc291cmNlX2NvbW1pdCcsJ2JpbmFyeV9zaGEyNTYnKX0sCiAgICAgICAgICAgICdjaGVja3MnOmNoZWNrcywnZXh0ZXJuYWxfdGNwX3VkcCc6J25vdF92ZXJpZmllZCcsJ2NlbnRyYWxfbW9uaXRvcmluZyc6J25vdF92ZXJpZmllZCcsJ3B1YmxpY2F0aW9uJzonbm90X3ZlcmlmaWVkJ30KCmRlZiB2ZXJpZnlfc2VydmljZShzdGF0ZSk6CiAgICByZXBvcnQ9ZGlhZ25vc2Uoc3RhdGUpCiAgICBmYWlsZWQ9W2l0ZW1bJ2xhYmVsJ10gZm9yIGl0ZW0gaW4gcmVwb3J0WydjaGVja3MnXSBpZiBub3QgaXRlbVsncGFzc2VkJ11dCiAgICBpZiBmYWlsZWQ6cmFpc2UgUnVudGltZUVycm9yKCfmnKzmnLrpqozmlLblpLHotKXvvJonKyfvvJsnLmpvaW4oZmFpbGVkKSkKCmRlZiB0dW5lX3NvdXJjZV9wb3J0cyhzdGF0ZSwgcHJvdG9jb2xzKToKICAgIHJlc2VydmVkPScsJy5qb2luKHN0cihQUk9UT0NPTFNbcF1bMV0pIGZvciBwIGluIHByb3RvY29scykKICAgIHJlY2VpcHQ9Y29uZmlndXJlX2VwaGVtZXJhbF9wb3J0cyhyZXNlcnZlZCxhcHBseT1UcnVlKQogICAgaWYgbm90IHJlY2VpcHQuZ2V0KCdhcHBsaWVkJykgb3IgcmVjZWlwdC5nZXQoJ25ld19yYW5nZScpIT0nMTAyNCA2NTUzNSc6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCfkuLTml7bnq6/lj6PphY3nva7mnKrpgJrov4fmoKHpqozvvIzlgZzmraLlronoo4UnKQogICAgc3RhdGUuc2V0ZGVmYXVsdCgnZXBoZW1lcmFsX3BvcnRfYmFja3VwcycsW10pLmFwcGVuZChyZWNlaXB0WydiYWNrdXAnXSkKICAgIHN0YXRlWydlcGhlbWVyYWxfcG9ydHMnXT1yZWNlaXB0CiAgICBhdG9taWMoUk9PVC8nc3RhdGUuanNvbicsanNvbi5kdW1wcyhzdGF0ZSxlbnN1cmVfYXNjaWk9RmFsc2UsaW5kZW50PTIpKQogICAgcHJpbnQoJ+S4tOaXtuerr+WPo+iMg+WbtCAxMDI04oCTNjU1MzXvvIzkv53nlZnkuJrliqHnq6/lj6PlkI7lj6/nlKggJytzdHIocmVjZWlwdFsnY2FwYWNpdHknXSksZmx1c2g9VHJ1ZSkKCgpkZWYgcmVzdG9yZV9zb3VyY2VfcG9ydHMoc3RhdGUpOgogICAgZm9yIGJhY2t1cCBpbiByZXZlcnNlZChzdGF0ZS5nZXQoJ2VwaGVtZXJhbF9wb3J0X2JhY2t1cHMnLFtdKSk6CiAgICAgICAgcGF0aD1QYXRoKGJhY2t1cCkKICAgICAgICBpZiBwYXRoLnBhcmVudCE9UGF0aCgnL3Jvb3QnKSBvciBub3QgcGF0aC5uYW1lLnN0YXJ0c3dpdGgoJ3doYWxlLWVwaGVtZXJhbC1tYXgtJyk6CiAgICAgICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcign5Li05pe256uv5Y+j5aSH5Lu96Lev5b6E5LiN5q2j56Gu77yM5YGc5q2i5oGi5aSNJykKICAgICAgICBydW4oJ3B5dGhvbjMnLHN0cihwYXRoLydyb2xsYmFjay5weScpKQogICAgc3RhdGVbJ2VwaGVtZXJhbF9wb3J0X2JhY2t1cHMnXT1bXQoKCmRlZiB0dW5lX2tlcm5lbChmYWN0cyk6CiAgICAiIiJDb25zZXJ2YXRpdmUsIHJlc291cmNlLWJvdW5kZWQgc2V0dGluZ3M7IG5ldmVyIHJld3JpdGUgZHJpdmVyIElSUSBvciBvZmZsb2FkIGJsaW5kbHkuCgogICAgVGhlIHF1ZXVlaW5nIGRpc2NpcGxpbmUgbXVzdCBiZSBmcV9jb2RlbCwgbm90IGZxOiBhIHNpbmcgaHlzdGVyaWEyIGluYm91bmQgaXMgYSBzaW5nbGUgVURQCiAgICBzb2NrZXQsIGFuZCBmcSB0cmVhdHMgYSBzb2NrZXQgYXMgb25lIGZsb3cgd2l0aCBhIDEwMC1wYWNrZXQgZmxvd19saW1pdCwgc28gdW5kZXIgbG9hZCBpdAogICAgZHJvcHBlZCB0aGUgbWFjaGluZSdzIGVudGlyZSBIWTIgdHJhZmZpYyAoZmxlZXQgZmluZGluZyAyMDI2LTA5LTE2OyB2MC4zLjQgYW5kIGVhcmxpZXIgc2V0IGZxKS4KICAgIFJldHVybnMgdGhlIGRlZmF1bHQtcm91dGUgZGV2aWNlIGFuZCBpdHMgcWRpc2MgYWZ0ZXIgdGhlIGNoYW5nZS4iIiIKICAgIHNldHRpbmdzPXsnbmV0LmNvcmUuc29tYXhjb25uJzo4MTkyLCduZXQuY29yZS5ybWVtX21heCc6ZmFjdHNbJ3NvY2tldF9idWZmZXInXSwnbmV0LmNvcmUud21lbV9tYXgnOmZhY3RzWydzb2NrZXRfYnVmZmVyJ10sJ25ldC5pcHY0LnRjcF9tdHVfcHJvYmluZyc6MSwnbmV0LmNvcmUuZGVmYXVsdF9xZGlzYyc6J2ZxX2NvZGVsJ30KICAgIG9sZD1qc29uLmxvYWRzKChST09ULydzeXNjdGwtYmVmb3JlLmpzb24nKS5yZWFkX3RleHQoKSkgaWYgKFJPT1QvJ3N5c2N0bC1iZWZvcmUuanNvbicpLmV4aXN0cygpIGVsc2Uge30KICAgIGZvciBrIGluIHNldHRpbmdzOgogICAgICAgIGlmIGsgbm90IGluIG9sZDogb2xkW2tdPXJ1bignc3lzY3RsJywnLW4nLGspLnN0ZG91dC5zdHJpcCgpCiAgICBydW4oJ21vZHByb2JlJywndGNwX2JicicsY2hlY2s9RmFsc2UpCiAgICBpZiAnYmJyJyBpbiBydW4oJ3N5c2N0bCcsJy1uJywnbmV0LmlwdjQudGNwX2F2YWlsYWJsZV9jb25nZXN0aW9uX2NvbnRyb2wnKS5zdGRvdXQuc3BsaXQoKToKICAgICAgICBpZiAnbmV0LmlwdjQudGNwX2Nvbmdlc3Rpb25fY29udHJvbCcgbm90IGluIG9sZDpvbGRbJ25ldC5pcHY0LnRjcF9jb25nZXN0aW9uX2NvbnRyb2wnXT1ydW4oJ3N5c2N0bCcsJy1uJywnbmV0LmlwdjQudGNwX2Nvbmdlc3Rpb25fY29udHJvbCcpLnN0ZG91dC5zdHJpcCgpCiAgICAgICAgc2V0dGluZ3NbJ25ldC5pcHY0LnRjcF9jb25nZXN0aW9uX2NvbnRyb2wnXT0nYmJyJwogICAgYXRvbWljKFJPT1QvJ3N5c2N0bC1iZWZvcmUuanNvbicsanNvbi5kdW1wcyhvbGQpKQogICAgYXRvbWljKCcvZXRjL3N5c2N0bC5kLzkwLXdoYWxlbm9kZS5jb25mJywnJy5qb2luKHN0cihrKSsnPScrc3RyKHYpKydcbicgZm9yIGssdiBpbiBzZXR0aW5ncy5pdGVtcygpKSwwbzY0NCkKICAgIHJ1bignc3lzY3RsJywnLXAnLCcvZXRjL3N5c2N0bC5kLzkwLXdoYWxlbm9kZS5jb25mJykKICAgICMgZGVmYXVsdF9xZGlzYyBvbmx5IGFwcGxpZXMgdG8gcWRpc2NzIGNyZWF0ZWQgbGF0ZXIuIFJlcGxhY2UgYW4gZnEgcm9vdCAob3IgdGhlIGZxIGNoaWxkcmVuIG9mCiAgICAjIGFuIG1xIHJvb3QpIG9uIHRoZSBkZWZhdWx0LXJvdXRlIGRldmljZSBub3c7IGFueSBvdGhlciBkaXNjaXBsaW5lIHNvbWVvbmUgY2hvc2UgaXMgbGVmdCBhbG9uZS4KICAgIHJvdXRlPXJ1bignaXAnLCctNCcsJ3JvdXRlJywnc2hvdycsJ2RlZmF1bHQnLGNoZWNrPUZhbHNlKS5zdGRvdXQuc3BsaXQoKQogICAgZGV2PXJvdXRlW3JvdXRlLmluZGV4KCdkZXYnKSsxXSBpZiAnZGV2JyBpbiByb3V0ZVs6LTFdIGVsc2UgJycKICAgIGlmIG5vdCBkZXYgb3Igbm90IHNodXRpbC53aGljaCgndGMnKTpyZXR1cm4gZGV2LCcnCiAgICBzaG93bj1ydW4oJ3RjJywncWRpc2MnLCdzaG93JywnZGV2JyxkZXYsY2hlY2s9RmFsc2UpLnN0ZG91dAogICAgaWYgcmUuc2VhcmNoKHInXnFkaXNjIGZxICcsc2hvd24scmUuTSk6CiAgICAgICAgaWYgc2hvd24uc3RhcnRzd2l0aCgncWRpc2MgbXEnKTpydW4oJ3RjJywncWRpc2MnLCdyZXBsYWNlJywnZGV2JyxkZXYsJ3Jvb3QnLCdoYW5kbGUnLCcxOicsJ21xJyxjaGVjaz1GYWxzZSkKICAgICAgICBlbHNlOnJ1bigndGMnLCdxZGlzYycsJ3JlcGxhY2UnLCdkZXYnLGRldiwncm9vdCcsJ2ZxX2NvZGVsJyxjaGVjaz1GYWxzZSkKICAgICAgICBzaG93bj1ydW4oJ3RjJywncWRpc2MnLCdzaG93JywnZGV2JyxkZXYsY2hlY2s9RmFsc2UpLnN0ZG91dAogICAgcmV0dXJuIGRldixzaG93bgoKZGVmIHdhaXRfbGlzdGVuaW5nKHNlbGVjdGVkKToKICAgIG1pc3Npbmc9c2VsZWN0ZWRbOl0KICAgIGZvciBfIGluIHJhbmdlKDM2KToKICAgICAgICBtaXNzaW5nPVtdCiAgICAgICAgZm9yIHByb3RvIGluIHNlbGVjdGVkOgogICAgICAgICAgICBzb2NrPSctbHVuJyBpZiBwcm90bz09J2h5MicgZWxzZSAnLWx0bicKICAgICAgICAgICAgaWYgbGVuKHJ1bignc3MnLHNvY2ssJ3Nwb3J0ID0gOicrc3RyKFBST1RPQ09MU1twcm90b11bMV0pKS5zdGRvdXQuc3BsaXRsaW5lcygpKTwyOm1pc3NpbmcuYXBwZW5kKHByb3RvKQogICAgICAgIGlmIG5vdCBtaXNzaW5nOmJyZWFrCiAgICAgICAgdGltZS5zbGVlcCg1KQogICAgcmV0dXJuIG1pc3NpbmcKCmRlZiByZXR1bmUoc3RhdGUpOgogICAgIiIiQWZ0ZXIgYSBDUFUvbWVtb3J5IHVwZ3JhZGU6IEdPTUFYUFJPQ1MsIEdPTUVNTElNSVQgYW5kIHNvY2tldCBidWZmZXJzIHdlcmUgZml4ZWQgYXQgaW5zdGFsbCB0aW1lLAogICAgc28gYW4gdXBncmFkZWQgbWFjaGluZSBrZXB0IHVzaW5nIHRoZSBvbGQgY29yZSBjb3VudC4gUmVjb21wdXRlIGZyb20gdGhlIGN1cnJlbnQgbWFjaGluZSwgZml4IHRoZQogICAgcWRpc2MsIGFuZCByZXN0YXJ0IHRoZSBiYWNrZW5kIG9ubHkgaWYgaXRzIGxpbWl0cyBjaGFuZ2VkLiIiIgogICAgaWYgc3RhdGUuZ2V0KCdwaGFzZScpIG5vdCBpbiAoJ2luc3RhbGxlZCcsJ3B1Ymxpc2hlZCcpIG9yIG5vdCBzdGF0ZS5nZXQoJ293bnNfc2VydmljZScpOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcign5pys5py65rKh5pyJ55Sx5pys5a6J6KOF5Zmo6KOF5aW955qEIFdoYWxlTm9kZe+8jOaXoOmcgCAtLXJldHVuZScpCiAgICBmYWN0cz1yZXNvdXJjZXMoKQogICAgdHVuZV9zb3VyY2VfcG9ydHMoc3RhdGUsc3RhdGUuZ2V0KCdwcm90b2NvbHMnKSBvciBbXSkKICAgIGRldixzaG93bj10dW5lX2tlcm5lbChmYWN0cykKICAgIHVuaXQ9VU5JVAogICAgdGV4dD11bml0LnJlYWRfdGV4dCgpCiAgICBuZXc9cmUuc3ViKHInR09NRU1MSU1JVD1cZCtNaUInLCdHT01FTUxJTUlUPScrc3RyKGZhY3RzWydnb19tZW1vcnlfbWliJ10pKydNaUInLHRleHQpCiAgICBuZXc9cmUuc3ViKHInR09NQVhQUk9DUz1cZCsnLCdHT01BWFBST0NTPScrc3RyKGZhY3RzWydjcHVzJ10pLG5ldykKICAgIGJlZm9yZT1zdGF0ZS5nZXQoJ3Jlc291cmNlcycpIG9yIHt9CiAgICBpZiBuZXchPXRleHQ6CiAgICAgICAgYXRvbWljKHVuaXQsbmV3LDBvNjQ0KQogICAgICAgIHJ1bignc3lzdGVtY3RsJywnZGFlbW9uLXJlbG9hZCcpCiAgICAgICAgcHJpbnQoJ+WQjuerryBDUFUv5YaF5a2Y5LiK6ZmQ5bey5Y+Y5YyW77yM6YeN5ZCvIHdoYWxlbm9kZe+8iOi/nuaOpeS8muaWreW8gOWHoOenku+8ieKApicsZmx1c2g9VHJ1ZSkKICAgICAgICBydW4oJ3N5c3RlbWN0bCcsJ3Jlc3RhcnQnLCd3aGFsZW5vZGUuc2VydmljZScpCiAgICAgICAgbWlzc2luZz13YWl0X2xpc3RlbmluZyhzdGF0ZS5nZXQoJ3Byb3RvY29scycpIG9yIFtdKQogICAgICAgIGlmIG1pc3Npbmc6cmFpc2UgUnVudGltZUVycm9yKCfph43lkK/lkI7nm5HlkKzmnKrlsLHnu6rvvIzljY/orq7vvJonKycsJy5qb2luKG1pc3NpbmcpKyfvvJvkvb/nlKggam91cm5hbGN0bCAtdSB3aGFsZW5vZGUg5qOA5p+lJykKICAgICAgICB2ZXJpZnlfc2VydmljZShzdGF0ZSkKICAgIHN0YXRlWydyZXNvdXJjZXMnXT1mYWN0cztzYXZlX3N0YXRlKHN0YXRlKQogICAgcWQ9JyAnLmpvaW4oc29ydGVkKHNldChyZS5maW5kYWxsKHInXnFkaXNjIChcUyspJyxzaG93bixyZS5NKSkpKSBvciAn5pyq55+lJwogICAgcHJpbnQoJ+W3suaMieW9k+WJjemFjee9ruiwg+aVtO+8mkNQVSAlc+KGkiVzIOaguO+8jOWGheWtmOS4iumZkCAlc+KGkiVzIE1pQu+8jOWll+aOpeWtl+e8k+WGsiAlcyDlrZfoioLvvIznvZHljaEgJXMg6Zif5YiX566X5rOVICVzJXMnJSgKICAgICAgICBiZWZvcmUuZ2V0KCdjcHVzJywnPycpLGZhY3RzWydjcHVzJ10sYmVmb3JlLmdldCgnZ29fbWVtb3J5X21pYicsJz8nKSxmYWN0c1snZ29fbWVtb3J5X21pYiddLGZhY3RzWydzb2NrZXRfYnVmZmVyJ10sCiAgICAgICAgZGV2IG9yICc/JyxxZCwnJyBpZiBuZXchPXRleHQgZWxzZSAn77yI5ZCO56uv5LiK6ZmQ5pyq5Y+Y77yM5pyq6YeN5ZCv77yJJykpCgoKZGVmIHJvd3MocmVzcG9uc2UpOgogICAgZGF0YSA9IHJlc3BvbnNlLmdldCgnZGF0YScpCiAgICBpZiBub3QgaXNpbnN0YW5jZShkYXRhLCBsaXN0KTogcmFpc2UgUnVudGltZUVycm9yKCdWMkJvYXJkIGdldE5vZGVzIOWTjeW6lOagvOW8j+S4jeWFvOWuuScpCiAgICByZXR1cm4gZGF0YQoKIyDnur/ot6/lkI3np7DkuI3lh4bluKYgSVDvvIhvd25lciAyMDI2LTExLTA377yJ77ya54K55YiG5oiW5qiq57q/5YiG6ZqU55qEIElQdjQg6YO9566X44CCCk5BTUVfSVA9cmUuY29tcGlsZShyJ1xkezEsM30oWy4tXSlcZHsxLDN9XDFcZHsxLDN9XDFcZHsxLDN9JykKCmRlZiBzZXR0bGVfbmFtZShzdGF0ZSxhbGxfbm9kZXMpOgogICAgIiIi5pys5py657q/6Lev5ZCN56ew55qE5YmN57yA77yI5Y2P6K6u5ZCN5LmL5YmN6YKj5q6177yJ44CCCiAgICDlt7LmnInmnKzku7vliqHnmoTpnaLmnb/ooYwg4oaSIOS7pemdouadv+S4uuWHhu+8iOWQjuWPsOWPr+iDveW3suaUueWQje+8ie+8m+WQpuWImeiHquWKqOWRveWQjSA9IOWcsOWMuiArIOS4pOS9jee8luWPt++8jAogICAg57yW5Y+35Y+W6Z2i5p2/6YeM5ZCM5Zyw5Yy66L+Y5rKh5Lq655So55qE5pyA5bCP5YC844CC5pen54mI6KOF5py655WZ5LiL55qE5bimIElQIOWQjeensOWcqOi/memHjOWOu+aOiSBJUCDph43mlrDnvJblj7fjgIIiIiIKICAgIG93bj1bc3RyKHguZ2V0KCduYW1lJykgb3IgJycpIGZvciB4IGluIGFsbF9ub2RlcyBpZiBzdGF0ZS5nZXQoJ25vbmNlJykgaW4gKHguZ2V0KCd0YWdzJykgb3IgW10pXQogICAgb3duPVtuLnNwbGl0KCcgwrcgJylbMF0gZm9yIG4gaW4gb3duIGlmICcgwrcgJyBpbiBuIGFuZCBub3QgTkFNRV9JUC5zZWFyY2gobildCiAgICBpZiBvd246IHJldHVybiBvd25bMF0KICAgIG5hbWU9c3RhdGVbJ25hbWUnXQogICAgaWYgTkFNRV9JUC5zZWFyY2gobmFtZSk6CiAgICAgICAgbmFtZT1yZS5zdWIocidbXHMuXy1dKyQnLCcnLHJlLnN1YihyJ1xzKycsJyAnLE5BTUVfSVAuc3ViKCcnLG5hbWUpKSkuc3RyaXAoKTtzdGF0ZVsnbmFtZV9hdXRvJ109VHJ1ZQogICAgaWYgbm90IHN0YXRlLmdldCgnbmFtZV9hdXRvJykgb3IgcmUuc2VhcmNoKHInIFxkezJ9JCcsbmFtZSk6IHJldHVybiBuYW1lCiAgICB1c2VkPXtzdHIoeC5nZXQoJ25hbWUnKSBvciAnJykgZm9yIHggaW4gYWxsX25vZGVzfQogICAgbj0xCiAgICB3aGlsZSBhbnkodS5zdGFydHN3aXRoKCclcyAlMDJkIMK3ICclKG5hbWUsbikpIGZvciB1IGluIHVzZWQpOiBuKz0xCiAgICByZXR1cm4gJyVzICUwMmQnJShuYW1lLG4pCk1BUks9J3duLWluc3RhbGxlcicKCmRlZiBzYXZlX3N0YXRlKHN0YXRlLHBoYXNlPU5vbmUpOgogICAgaWYgcGhhc2U6c3RhdGVbJ3BoYXNlJ109cGhhc2UKICAgIGF0b21pYyhST09ULydzdGF0ZS5qc29uJyxqc29uLmR1bXBzKHN0YXRlLGluZGVudD0yKSkKCmRlZiBzZWNyZXQoYXJncyx2YWx1ZSxwYXRoLGxhYmVsKToKICAgIGlmIHZhbHVlOnJldHVybiB2YWx1ZQogICAgaWYgcGF0aDpyZXR1cm4gcGF0aC5yZWFkX3RleHQoKS5zdHJpcCgpCiAgICBpZiBhcmdzLm5vbl9pbnRlcmFjdGl2ZTpyYWlzZSBWYWx1ZUVycm9yKCfpnZ7kuqTkupLmqKHlvI/nvLrlsJHlr4bpkqXlj4LmlbDmiJblh63mja7mlofku7YnKQogICAgcmV0dXJuIGdldHBhc3MuZ2V0cGFzcyhsYWJlbCkKCmRlZiBhZG1pbl90b2tlbihhcmdzKToKICAgIHRva2VuPXNlY3JldChhcmdzLGFyZ3MuYWRtaW5fdG9rZW4sYXJncy5hZG1pbl90b2tlbl9maWxlLCfor7fovpPlhaXpnaLmnb/nrqHnkIblkZjmjojmnYPlgLzvvIjpmpDol4/ovpPlhaXvvIzkuI3kv53lrZjvvInvvJonKQogICAgaWYgbm90IHRva2VuOnJhaXNlIFZhbHVlRXJyb3IoJ+mdouadv+euoeeQhuWRmOaOiOadg+WAvOS4jeiDveS4uuepuicpCiAgICByZXR1cm4gdG9rZW4KCmRlZiBvdXJzKHN0YXRlLGFkbWluKToKICAgICMgKHR5cGUsaWQpIOaJjeWUr+S4gO+8muS4jeWQjOWNj+iuruihqOeahCBJRCDkvJrph43lpI3jgIIKICAgIHJldHVybiB7KHguZ2V0KCd0eXBlJyksaW50KHhbJ2lkJ10pKTp4IGZvciB4IGluIHJvd3MocmVxdWVzdChzdGF0ZVsnYWRtaW5fdXJsJ10rJy9zZXJ2ZXIvbWFuYWdlL2dldE5vZGVzJyxhZG1pbikpCiAgICAgICAgICAgIGlmIHN0YXRlLmdldCgnbm9uY2UnKSBpbiAoeC5nZXQoJ3RhZ3MnKSBvciBbXSl9CgpkZWYgc2V0X3Nob3coc3RhdGUsYWRtaW4sdmFsdWUpOgogICAgZm9yIHByb3RvLG5pZCBpbiBzdGF0ZS5nZXQoJ2lkcycse30pLml0ZW1zKCk6CiAgICAgICAgcmVzdWx0PXJlcXVlc3Qoc3RhdGVbJ2FkbWluX3VybCddKycvc2VydmVyLycrUFJPVE9DT0xTW3Byb3RvXVswXSsnL3VwZGF0ZScsYWRtaW4seydpZCc6bmlkLCdzaG93Jzp2YWx1ZX0pCiAgICAgICAgaWYgcmVzdWx0LmdldCgnZGF0YScpIGlzIG5vdCBUcnVlOnJhaXNlIFJ1bnRpbWVFcnJvcign6Z2i5p2/5pyq56Gu6K6k5pi+56S654q25oCB5L+u5pS577yaJytwcm90bykKICAgIGN1cnJlbnQ9b3VycyhzdGF0ZSxhZG1pbikKICAgIGZvciBwcm90byxuaWQgaW4gc3RhdGUuZ2V0KCdpZHMnLHt9KS5pdGVtcygpOgogICAgICAgIHJvdz1jdXJyZW50LmdldCgoUFJPVE9DT0xTW3Byb3RvXVswXSxuaWQpKQogICAgICAgIGlmIG5vdCByb3cgb3IgaW50KHJvdy5nZXQoJ3Nob3cnLDApKSE9dmFsdWU6cmFpc2UgUnVudGltZUVycm9yKCfpnaLmnb/mmL7npLrnirbmgIHmoLjlr7nlpLHotKXvvJonK3Byb3RvKQogICAgc3RhdGVbJ3B1Ymxpc2hlZCddPWJvb2wodmFsdWUpO3NhdmVfc3RhdGUoc3RhdGUpCgpkZWYgaW5zdGFsbF9tb25pdG9yKGFyZ3Msc3RhdGUpOgogICAgIiIiWmFiYml4IGFnZW50Mu+8iFBTSyDoh6rliqjms6jlhozvvIkrIGZsZWV0IOmHh+mbhuiEmuacrO+8m+aOpeWFpeWMheadpeiHquengeacieS4i+i9veW5tuagoemqjOWTiOW4jOOAgiIiIgogICAgaWYgbm90IHN0YXRlLmdldCgnbW9uaXRvcl91cmwnKSBhbmQgc3RhdGUuZ2V0KCdyZWxlYXNlX21hbmlmZXN0Jyk6CiAgICAgICAgYXV0aD1kb3dubG9hZF9hdXRoKGFyZ3Msc3RhdGVbJ3JlbGVhc2VfbWFuaWZlc3QnXSxzdGF0ZVsncmVsZWFzZV9tYW5pZmVzdCddKQogICAgICAgIHN0YXRlLnVwZGF0ZShtb25pdG9yX2VudHJ5KHJlcXVlc3Qoc3RhdGVbJ3JlbGVhc2VfbWFuaWZlc3QnXSxhdXRoKSkpCiAgICBpZiBub3Qgc3RhdGUuZ2V0KCdtb25pdG9yX3VybCcpOnJhaXNlIFJ1bnRpbWVFcnJvcign5Y+R5biD5riF5Y2V5rKh5pyJ5o+Q5L6b55uR5o6n5o6l5YWl5YyF77yM5peg5rOV6Ieq5Yqo5o6l5YWlIFphYmJpeC9HcmFmYW5hJykKICAgIG5hbWU9J0FVVE8tJytzdGF0ZVsnbm9uY2UnXS51cHBlcigpCiAgICBpZiAnb3duc19hZ2VudCcgbm90IGluIHN0YXRlOgogICAgICAgIHN0YXRlWydvd25zX2FnZW50J109c2h1dGlsLndoaWNoKCd6YWJiaXhfYWdlbnQyJykgaXMgTm9uZTtzYXZlX3N0YXRlKHN0YXRlKQogICAgYXV0aD1kb3dubG9hZF9hdXRoKGFyZ3Msc3RhdGVbJ21vbml0b3JfdXJsJ10sc3RhdGUuZ2V0KCdyZWxlYXNlX21hbmlmZXN0Jykgb3Igc3RhdGVbJ21vbml0b3JfdXJsJ10pCiAgICByZXE9dXJsbGliLnJlcXVlc3QuUmVxdWVzdChzdGF0ZVsnbW9uaXRvcl91cmwnXSxoZWFkZXJzPXsnQXV0aG9yaXphdGlvbic6YXV0aH0gaWYgYXV0aCBlbHNlIHt9KQogICAgdHJ5OgogICAgICAgIHdpdGggdXJsbGliLnJlcXVlc3QuYnVpbGRfb3BlbmVyKE5vUmVkaXJlY3QoKSkub3BlbihyZXEsdGltZW91dD02MCkgYXMgc291cmNlOgogICAgICAgICAgICBib2R5PXNvdXJjZS5yZWFkKDQqMTAyNCoxMDI0KzEpCiAgICBleGNlcHQgKHVybGxpYi5lcnJvci5VUkxFcnJvcixPU0Vycm9yKTpyYWlzZSBSdW50aW1lRXJyb3IoJ+ebkeaOp+aOpeWFpeWMheS4i+i9veWksei0pScpIGZyb20gTm9uZQogICAgaWYgbGVuKGJvZHkpPjQqMTAyNCoxMDI0IG9yIGhhc2hsaWIuc2hhMjU2KGJvZHkpLmhleGRpZ2VzdCgpIT1zdGF0ZVsnbW9uaXRvcl9zaGEyNTYnXToKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+ebkeaOp+aOpeWFpeWMhSBTSEEyNTYg5qCh6aqM5aSx6LSlJykKICAgIHByaW50KCfmraPlnKjlronoo4UgWmFiYml4IOebkeaOp++8iCcrbmFtZSsn77yJ4oCmJyxmbHVzaD1UcnVlKQogICAgZmQscGF0aD10ZW1wZmlsZS5ta3N0ZW1wKGRpcj1zdHIoUk9PVCkscHJlZml4PScubW9uaXRvci0nKQogICAgdHJ5OgogICAgICAgIHdpdGggb3MuZmRvcGVuKGZkLCd3YicpIGFzIGY6Zi53cml0ZShib2R5KQogICAgICAgICMg5o6l5YWl5YyF5ZCr6Ieq5Yqo5rOo5YaMIFBTS++8muS4jeWbnuaYvuWFtui+k+WHuu+8jOWPquWPlue7k+aenOihjOOAggogICAgICAgIHA9c3VicHJvY2Vzcy5ydW4oWydiYXNoJyxwYXRoLG5hbWUsJ3doYWxlOmxhbmRpbmc6YXV0b18nK3N0YXRlWydub25jZSddXSx0ZXh0PVRydWUsCiAgICAgICAgICAgICAgICAgICAgICAgICBzdGRvdXQ9c3VicHJvY2Vzcy5QSVBFLHN0ZGVycj1zdWJwcm9jZXNzLlNURE9VVCx0aW1lb3V0PTkwMCkKICAgIGZpbmFsbHk6CiAgICAgICAgb3MudW5saW5rKHBhdGgpCiAgICBpZiBwLnJldHVybmNvZGUgb3IgJ01PTklUT1JfUkVBRFknIG5vdCBpbiBwLnN0ZG91dDoKICAgICAgICBoaW50PVt4IGZvciB4IGluIHAuc3Rkb3V0LnNwbGl0bGluZXMoKSBpZiB4LnN0YXJ0c3dpdGgoKCdVTlNVUFBPUlRFRF9SRUxFQVNFJywnRE9XTkxPQURfRkFJTEVEJywnU0hBX01JU01BVENIJywnUkVTVUxUJywnZHBrZyBmYWlsZWQnKSldCiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCdaYWJiaXgg55uR5o6n5a6J6KOF5aSx6LSlJysoJ++8micraGludFstMV1bOjE2MF0gaWYgaGludCBlbHNlICcnKSsn77yb5L+u5aSN5ZCO6YeN5paw6L+Q6KGM5Y6f5ZG95Luk57ut6LeRJykKICAgIHN0YXRlWydtb25pdG9yJ109bmFtZTtzYXZlX3N0YXRlKHN0YXRlKQoKZGVmIHdhaXRfc3luYyhzdGF0ZSxhZG1pbix0aW1lb3V0PTYwMCk6CiAgICAiIiLmupDnq5nlr7notKbvvIjmr4/liIbpkp/vvInlrozmiJAgbm9kZV9vcHPjgIHoioLngrnliIbnu4TjgIHnm5HmjqfmuIXljZXlkI7kvJrnu5npnaLmnb/ooYzmiZMgd24tc3luY2Vk44CCIiIiCiAgICBwcmludCgn562J5b6F5rqQ56uZ6Ieq5Yqo5o6l5YWl6LCD5bqm44CB6IqC54K55YiG57uE5ZKM55uR5o6n77yI6YCa5bi4IDHigJMzIOWIhumSn++8ieKApicsZmx1c2g9VHJ1ZSkKICAgIGRlYWRsaW5lPXRpbWUudGltZSgpK3RpbWVvdXQ7bGFzdD1Ob25lCiAgICB3aGlsZSB0aW1lLnRpbWUoKTxkZWFkbGluZToKICAgICAgICBjdXJyZW50PW91cnMoc3RhdGUsYWRtaW4pCiAgICAgICAgdGFncz1bdCBmb3Igcm93IGluIGN1cnJlbnQudmFsdWVzKCkgZm9yIHQgaW4gKHJvdy5nZXQoJ3RhZ3MnKSBvciBbXSldCiAgICAgICAgaWYgY3VycmVudCBhbmQgYWxsKCd3bi1zeW5jZWQnIGluIChyb3cuZ2V0KCd0YWdzJykgb3IgW10pIGZvciByb3cgaW4gY3VycmVudC52YWx1ZXMoKSk6CiAgICAgICAgICAgIHByaW50KCfmupDnq5nmjqXlhaXlrozmiJDvvJrlt7LnmbvorrDosIPluqbjgIHliqDlhaXoioLngrnliIbnu4TjgIHnm5Hmjqflt7LkuIrnur/vvIznlKjmiLforqLpmIXlj6/ku6Xmi7/liLDov5nlj7DoioLngrnjgIInKTtyZXR1cm4gVHJ1ZQogICAgICAgIGVycm9ycz1zb3J0ZWQoe3RbOTpdIGZvciB0IGluIHRhZ3MgaWYgdC5zdGFydHN3aXRoKCd3bi1lcnJvcjonKX0pCiAgICAgICAgaWYgZXJyb3JzIGFuZCBlcnJvcnMhPWxhc3Q6CiAgICAgICAgICAgIHByaW50KCfmupDnq5nmraPlnKjph43or5XvvJonKyfjgIEnLmpvaW4oZXJyb3JzKSsn77yI5Lya6Ieq5Yqo57un57ut77yJJyxmbHVzaD1UcnVlKTtsYXN0PWVycm9ycwogICAgICAgIHRpbWUuc2xlZXAoMTUpCiAgICBwcmludCgn5rqQ56uZIDEwIOWIhumSn+WGheacquehruiupOaOpeWFpeWujOaIkOOAguiKgueCueW3suWcqOmdouadv+aYvuekuu+8m+a6kOermeS8mue7p+e7reiHquWKqOmHjeivle+8jOWPr+eojeWQjueUqCAtLXN0YXR1cyDmn6XnnIvjgIInKQogICAgcmV0dXJuIEZhbHNlCgpkZWYgc3NoX3BvcnQoKToKICAgIG91dD1ydW4oJ3NzJywnLWx0bnBIJyxjaGVjaz1GYWxzZSkuc3Rkb3V0CiAgICBmb3IgbGluZSBpbiBvdXQuc3BsaXRsaW5lcygpOgogICAgICAgIGlmICcic3NoZCInIGluIGxpbmU6CiAgICAgICAgICAgIHBvcnQ9bGluZS5zcGxpdCgpWzNdLnJzcGxpdCgnOicsMSlbLTFdCiAgICAgICAgICAgIGlmIHBvcnQuaXNkaWdpdCgpOnJldHVybiBpbnQocG9ydCkKICAgIHJldHVybiAyMgoKZGVmIHJlbW92ZV9tb25pdG9yKHN0YXRlKToKICAgIGlmIG5vdCBzdGF0ZS5nZXQoJ21vbml0b3InKTpyZXR1cm4KICAgIHJ1bignc3lzdGVtY3RsJywnZGlzYWJsZScsJy0tbm93Jywnd2hhbGUtY29ubnRyYWNrLXByb3RvLnRpbWVyJyxjaGVjaz1GYWxzZSkKICAgIGZvciBwYXRoIGluICgnL2V0Yy9zeXN0ZW1kL3N5c3RlbS93aGFsZS1jb25udHJhY2stcHJvdG8uc2VydmljZScsJy9ldGMvc3lzdGVtZC9zeXN0ZW0vd2hhbGUtY29ubnRyYWNrLXByb3RvLnRpbWVyJywKICAgICAgICAgICAgICAgICAnL3Vzci9sb2NhbC9zYmluL3doYWxlLWNvbm50cmFjay1wcm90bycsJy9ldGMvemFiYml4L3doYWxlLXN0YWNrLnNoJywnL2V0Yy96YWJiaXgvd2hhbGUucHNrJywKICAgICAgICAgICAgICAgICAnL2V0Yy96YWJiaXgvemFiYml4X2FnZW50Mi5kL3BsdWdpbnMuZC93aGFsZS1pbnZlbnRvcnkuY29uZicpOgogICAgICAgIFBhdGgocGF0aCkudW5saW5rKG1pc3Npbmdfb2s9VHJ1ZSkKICAgIGlmIHN0YXRlLmdldCgnb3duc19hZ2VudCcpOgogICAgICAgIHJ1bignc3lzdGVtY3RsJywnZGlzYWJsZScsJy0tbm93JywnemFiYml4LWFnZW50MicsY2hlY2s9RmFsc2UpCiAgICAgICAgaWYgc2h1dGlsLndoaWNoKCdhcHQtZ2V0Jyk6cnVuKCdlbnYnLCdERUJJQU5fRlJPTlRFTkQ9bm9uaW50ZXJhY3RpdmUnLCdhcHQtZ2V0JywncHVyZ2UnLCcteScsJy1xcScsJ3phYmJpeC1hZ2VudDInLGNoZWNrPUZhbHNlKQogICAgICAgIGVsaWYgc2h1dGlsLndoaWNoKCdkbmYnKTpydW4oJ2RuZicsJ3JlbW92ZScsJy15JywnemFiYml4LWFnZW50MicsY2hlY2s9RmFsc2UpCiAgICBlbHNlOgogICAgICAgIHJ1bignc3lzdGVtY3RsJywncmVzdGFydCcsJ3phYmJpeC1hZ2VudDInLGNoZWNrPUZhbHNlKQoKZGVmIHVuaW5zdGFsbChhcmdzLHN0YXRlKToKICAgIGlmIGhhc19hZGRpdGlvbmFsX2lwX2luc3RhbmNlcygpOnJhaXNlIFJ1bnRpbWVFcnJvcign5a2Y5Zyo6ZmE5YqgIElQIOWunuS+i++8jOS4jeiDveWIoOmZpOWFseeUqOaguOW/g+OAgemFjee9ruWSjOebkeaOp++8m+ivt+WFiOmAkOWunuS+i+WkhOeQhicpCiAgICBpZiBub3Qgc3RhdGUuZ2V0KCdpZHMnKSBhbmQgbm90IHN0YXRlLmdldCgnb3duc19zZXJ2aWNlJyk6cmFpc2UgUnVudGltZUVycm9yKCfmnKzmnLrmsqHmnInlronoo4Xlmajku7vliqHvvIzml6DpnIDljbjovb0nKQogICAgaWYgbm90IGFyZ3MueWVzOgogICAgICAgIGlmIGFyZ3Mubm9uX2ludGVyYWN0aXZlOnJhaXNlIFZhbHVlRXJyb3IoJ+mdnuS6pOS6kuWNuOi9vemcgOimgSAtLXllcyDnoa7orqQnKQogICAgICAgIGlmIHByb21wdCgn5bCG6ZqQ6JeP5bm25Yig6Zmk6Z2i5p2/6IqC54K544CB5Y246L29IFdoYWxlTm9kZSDlkoznm5HmjqfjgILovpPlhaUgeWVzIOehruiupCcpIT0neWVzJzoKICAgICAgICAgICAgcHJpbnQoJ+W3suWPlua2iO+8jOacquWBmuS7u+S9leS/ruaUueOAgicpO3JldHVybgogICAgYWRtaW49YWRtaW5fdG9rZW4oYXJncykgaWYgc3RhdGUuZ2V0KCdpZHMnKSBlbHNlIE5vbmUKICAgIGlmIGFkbWluIGFuZCBzdGF0ZS5nZXQoJ3B1Ymxpc2hlZCcpOgogICAgICAgIHNldF9zaG93KHN0YXRlLGFkbWluLDApO3ByaW50KCfpnaLmnb/lt7LpmpDol4/jgIInLGZsdXNoPVRydWUpCiAgICBpZiBQYXRoKCcvZXRjL3N5c3RlbWQvc3lzdGVtL3doYWxlbm9kZS1pcC1wb29sLnRpbWVyJykuZXhpc3RzKCk6CiAgICAgICAgcnVuKCdzeXN0ZW1jdGwnLCdkaXNhYmxlJywnLS1ub3cnLCd3aGFsZW5vZGUtaXAtcG9vbC50aW1lcicsY2hlY2s9RmFsc2UpCiAgICAgICAgcnVuKCdzeXN0ZW1jdGwnLCdzdG9wJywnd2hhbGVub2RlLWlwLXBvb2wuc2VydmljZScsY2hlY2s9RmFsc2UpCiAgICAgICAgZm9yIG5hbWUgaW4gKCd3aGFsZW5vZGUtaXAtcG9vbC50aW1lcicsJ3doYWxlbm9kZS1pcC1wb29sLnNlcnZpY2UnKToKICAgICAgICAgICAgKFBhdGgoJy9ldGMvc3lzdGVtZC9zeXN0ZW0nKS9uYW1lKS51bmxpbmsobWlzc2luZ19vaz1UcnVlKQogICAgcnVuKCdzeXN0ZW1jdGwnLCdkaXNhYmxlJywnLS1ub3cnLCd3aGFsZW5vZGUuc2VydmljZScsY2hlY2s9RmFsc2UpCiAgICBydW4oJ3N5c3RlbWN0bCcsJ2Rpc2FibGUnLCctLW5vdycsJ3doYWxlbm9kZS1lZ3Jlc3Muc2VydmljZScsY2hlY2s9RmFsc2UpCiAgICBpZiBhZG1pbjoKICAgICAgICAjIOWFiOWBnOacrOacuuWQjuerr+WGjeWIoOmdouadv+ihjO+8muS7jeWcqOaLiemFjee9rueahOWQjuerr+mBh+WIsOiiq+WIoOeahCBOb2RlSUQg5Lya5oql6ZSZ6YeN5ZCv44CCCiAgICAgICAgY3VycmVudD1vdXJzKHN0YXRlLGFkbWluKQogICAgICAgIGZvciBwcm90byxuaWQgaW4gc3RhdGVbJ2lkcyddLml0ZW1zKCk6CiAgICAgICAgICAgIGlmIChQUk9UT0NPTFNbcHJvdG9dWzBdLG5pZCkgaW4gY3VycmVudDoKICAgICAgICAgICAgICAgIHJlc3VsdD1yZXF1ZXN0KHN0YXRlWydhZG1pbl91cmwnXSsnL3NlcnZlci8nK1BST1RPQ09MU1twcm90b11bMF0rJy9kcm9wJyxhZG1pbix7J2lkJzpuaWR9KQogICAgICAgICAgICAgICAgaWYgcmVzdWx0LmdldCgnZGF0YScpIGlzIG5vdCBUcnVlOnJhaXNlIFJ1bnRpbWVFcnJvcign6Z2i5p2/5pyq56Gu6K6k5Yig6Zmk6IqC54K577yaJytwcm90bykKICAgICAgICBpZiBvdXJzKHN0YXRlLGFkbWluKTpyYWlzZSBSdW50aW1lRXJyb3IoJ+mdouadv+S7jeacieacrOS7u+WKoeiKgueCue+8jOWNuOi9veWBnOatou+8m+acrOacuuacjeWKoeW3suWBnOatou+8jOWPr+mHjeaWsOi/kOihjOe7reWBmicpCiAgICAgICAgcHJpbnQoJ+mdouadv+iKgueCueW3suWIoOmZpO+8m+a6kOermeS8muWcqCAx4oCTMiDliIbpkp/lhoXoh6rliqjliKDpmaTnm5HmjqflkozosIPluqbnmbvorrDjgIInLGZsdXNoPVRydWUpCiAgICBpZiBzdGF0ZS5nZXQoJ293bnNfZWdyZXNzJyk6cnVuKCduZnQnLCdkZWxldGUnLCd0YWJsZScsJ2luZXQnLCd3aGFsZW5vZGVfZWdyZXNzJyxjaGVjaz1GYWxzZSkKICAgIHJlc3RvcmVfc291cmNlX3BvcnRzKHN0YXRlKQogICAgcGF0aD1ST09ULydzeXNjdGwtYmVmb3JlLmpzb24nCiAgICBpZiBwYXRoLmV4aXN0cygpOgogICAgICAgIGZvciBrZXksdmFsdWUgaW4ganNvbi5sb2FkcyhwYXRoLnJlYWRfdGV4dCgpKS5pdGVtcygpOnJ1bignc3lzY3RsJywnLXcnLGtleSsnPScrc3RyKHZhbHVlKSxjaGVjaz1GYWxzZSkKICAgIGZvciBpdGVtIGluIFsnL2V0Yy9zeXN0ZW1kL3N5c3RlbS93aGFsZW5vZGUuc2VydmljZScsJy9ldGMvc3lzdGVtZC9zeXN0ZW0vd2hhbGVub2RlLWVncmVzcy5zZXJ2aWNlJywnL2V0Yy93aGFsZW5vZGUtZWdyZXNzLm5mdCcsJy9ldGMvc3lzY3RsLmQvOTAtd2hhbGVub2RlLmNvbmYnXToKICAgICAgICBQYXRoKGl0ZW0pLnVubGluayhtaXNzaW5nX29rPVRydWUpCiAgICByZW1vdmVfbW9uaXRvcihzdGF0ZSkKICAgIHJ1bignc3lzdGVtY3RsJywnZGFlbW9uLXJlbG9hZCcsY2hlY2s9RmFsc2UpCiAgICBzaHV0aWwucm10cmVlKHN0cihDT05GKSxpZ25vcmVfZXJyb3JzPVRydWUpCiAgICBzaHV0aWwucm10cmVlKCcvb3B0L3doYWxlbm9kZScsaWdub3JlX2Vycm9ycz1UcnVlKQogICAgcnVuKCd1c2VyZGVsJywnd2hhbGVub2RlJyxjaGVjaz1GYWxzZSkKICAgIHNodXRpbC5ybXRyZWUoc3RyKFJPT1QpLGlnbm9yZV9lcnJvcnM9VHJ1ZSkKICAgIHByaW50KCfljbjovb3lrozmiJDvvJpXaGFsZU5vZGXjgIHlh7rlj6Pop4TliJnjgIHns7vnu5/lj4LmlbDjgIFaYWJiaXgg55uR5o6n5ZKM6Z2i5p2/6IqC54K55Z2H5bey56e76Zmk44CCJykKCmRlZiBzdW1tYXJ5KHN0YXRlKToKICAgIHNob3duPSfpnaLmnb/mmL7npLrkuK0nIGlmIHN0YXRlLmdldCgncHVibGlzaGVkJykgZWxzZSAn6Z2i5p2/5bey6ZqQ6JePJwogICAgcmV0dXJuICflt7Llronoo4UgwrcgJytzaG93bisnIMK3IOiKgueCuSAnKycsICcuam9pbihwKycjJytzdHIobikgZm9yIHAsbiBpbiBzdGF0ZS5nZXQoJ2lkcycse30pLml0ZW1zKCkpKygnIMK3IOebkeaOpyAnK3N0YXRlWydtb25pdG9yJ10gaWYgc3RhdGUuZ2V0KCdtb25pdG9yJykgZWxzZSAnJykKCmRlZiBtYW5hZ2UoYXJncyxzdGF0ZSk6CiAgICBpZiBhcmdzLnVuaW5zdGFsbDpyZXR1cm4gdW5pbnN0YWxsKGFyZ3Msc3RhdGUpCiAgICBpZiBhcmdzLmhpZGUgb3IgYXJncy5zaG93OgogICAgICAgIGlmIG5vdCBzdGF0ZS5nZXQoJ2lkcycpOnJhaXNlIFJ1bnRpbWVFcnJvcign5pys5py65rKh5pyJ5bey5Yib5bu655qE6Z2i5p2/6IqC54K5JykKICAgICAgICBzZXRfc2hvdyhzdGF0ZSxhZG1pbl90b2tlbihhcmdzKSwxIGlmIGFyZ3Muc2hvdyBlbHNlIDApCiAgICAgICAgcHJpbnQoJ+mdouadv+W3sicrKCfmmL7npLonIGlmIGFyZ3Muc2hvdyBlbHNlICfpmpDol48nKSsn77yaJytzdW1tYXJ5KHN0YXRlKSk7cmV0dXJuCiAgICBwcmludChzdW1tYXJ5KHN0YXRlKSkKICAgIGNob2ljZT1wcm9tcHQoJ+mAieaLqeaTjeS9nO+8mjEg5pys5py66Ieq5qOAICAyIOmdouadv+makOiXjyAgMyDpnaLmnb/ph43mlrDmmL7npLogIDQg5Y246L29ICAwIOmAgOWHuicsJzAnKQogICAgaWYgY2hvaWNlPT0nMSc6CiAgICAgICAgZm9yIGl0ZW0gaW4gZGlhZ25vc2Uoc3RhdGUpWydjaGVja3MnXTpwcmludCgoJ+mAmui/hycgaWYgaXRlbVsncGFzc2VkJ10gZWxzZSAn5aSx6LSlJykrJ++8micraXRlbVsnbGFiZWwnXSkKICAgIGVsaWYgY2hvaWNlIGluICgnMicsJzMnKToKICAgICAgICBzZXRfc2hvdyhzdGF0ZSxhZG1pbl90b2tlbihhcmdzKSwxIGlmIGNob2ljZT09JzMnIGVsc2UgMCk7cHJpbnQoJ+WujOaIkO+8micrc3VtbWFyeShzdGF0ZSkpCiAgICBlbGlmIGNob2ljZT09JzQnOnVuaW5zdGFsbChhcmdzLHN0YXRlKQoKZGVmIHJlc3VtZV9ncm91cChyZXF1ZXN0ZWQsc3RhdGUsbm9kZXM9Tm9uZSk6CiAgICBleGlzdGluZz1zdGF0ZS5nZXQoJ25vZGVfZ3JvdXAnKQogICAgaWYgc3RhdGUuZ2V0KCdpZHMnKSBhbmQgbm90IGV4aXN0aW5nOgogICAgICAgIGlmIG5vZGVzIGlzIE5vbmU6cmV0dXJuIE5vbmUKICAgICAgICBpZGVudGl0aWVzPXsoUFJPVE9DT0xTW3BdWzBdLGludChuaWQpKSBmb3IgcCxuaWQgaW4gc3RhdGVbJ2lkcyddLml0ZW1zKCl9CiAgICAgICAgZ3JvdXBzPXNldCgpCiAgICAgICAgZm9yIHJvdyBpbiBub2RlczoKICAgICAgICAgICAgaWYgKHJvdy5nZXQoJ3R5cGUnKSxpbnQocm93LmdldCgnaWQnLDApKSkgbm90IGluIGlkZW50aXRpZXM6Y29udGludWUKICAgICAgICAgICAgaWYgcm93LmdldCgnaG9zdCcpIT1zdGF0ZS5nZXQoJ2hvc3QnKSBvciBzdGF0ZS5nZXQoJ25vbmNlJykgbm90IGluIChyb3cuZ2V0KCd0YWdzJykgb3IgW10pOgogICAgICAgICAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCfml6foioLngrnouqvku73moLjlr7nlpLHotKXvvIzmnKrkv67mlLnliIbnu4TmiJbmnI3liqEnKQogICAgICAgICAgICBncm91cHMudXBkYXRlKHRhZ1s5Ol0gZm9yIHRhZyBpbiAocm93LmdldCgndGFncycpIG9yIFtdKSBpZiBpc2luc3RhbmNlKHRhZyxzdHIpIGFuZCB0YWcuc3RhcnRzd2l0aCgnd24tZ3JvdXA6JykpCiAgICAgICAgaWYgbGVuKGdyb3VwcykhPTE6cmFpc2UgUnVudGltZUVycm9yKCfml6Dms5XllK/kuIDmgaLlpI3ljp/oioLngrnliIbnu4TvvIzmnKrkv67mlLnmnI3liqHvvJvor7fmoLjlr7nml6foioLngrkgd24tZ3JvdXAg5qCH562+JykKICAgICAgICBleGlzdGluZz1ncm91cHMucG9wKCkKICAgICAgICBwcmludCgn5bey5LuO5pen6IqC54K55qCH562+5oGi5aSN5YiG57uE77yaJytleGlzdGluZyxmbHVzaD1UcnVlKQogICAgY2hvc2VuPWV4aXN0aW5nIGlmIHN0YXRlLmdldCgnaWRzJykgZWxzZSByZXF1ZXN0ZWQgb3IgZXhpc3Rpbmcgb3IgJ2xlZ2FjeV9hbGwnCiAgICBpZiBub3QgaXNpbnN0YW5jZShjaG9zZW4sc3RyKSBvciBub3QgcmUuZnVsbG1hdGNoKCdbYS16MC05X117MSw0OH0nLGNob3Nlbik6cmFpc2UgVmFsdWVFcnJvcign572R5YWz6IqC54K55YiG57uE5qC85byP5peg5pWIJykKICAgIGlmIHN0YXRlLmdldCgnaWRzJykgYW5kIHJlcXVlc3RlZCBhbmQgcmVxdWVzdGVkIT1jaG9zZW46CiAgICAgICAgcHJpbnQoJ+i/veWKoC/nu63ot5Hmsr/nlKjljp/liIbnu4QgJytjaG9zZW4rJ++8m+W/veeVpeWRveS7pOS4reeahCAtLW5vZGUtZ3JvdXAgJytyZXF1ZXN0ZWQrJ++8jOS4jei/geenu+W3suacieiKgueCuScsZmx1c2g9VHJ1ZSkKICAgIHJldHVybiBjaG9zZW4KCgpkZWYgYmFja2VuZF9wcmVmbGlnaHQoc3RhdGUpOgogICAgZm9yIHNlcnZpY2UgaW4gKCdWMmJYLnNlcnZpY2UnLCd3aGFsZW5vZGUuc2VydmljZScpOgogICAgICAgIGlmIHJ1bignc3lzdGVtY3RsJywnaXMtYWN0aXZlJywnLS1xdWlldCcsc2VydmljZSxjaGVjaz1GYWxzZSkucmV0dXJuY29kZTpjb250aW51ZQogICAgICAgIGlmIHNlcnZpY2UhPSd3aGFsZW5vZGUuc2VydmljZScgb3Igbm90IHN0YXRlLmdldCgnb3duc19zZXJ2aWNlJyk6CiAgICAgICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcign5Y+R546w5bey5pyJ5ZCO56uv5pyN5Yqh77yM5pyq6KaG55uW77yaJytzZXJ2aWNlKQogICAgICAgIHBpZD1ydW4oJ3N5c3RlbWN0bCcsJ3Nob3cnLCctcCcsJ01haW5QSUQnLCctLXZhbHVlJyxzZXJ2aWNlKS5zdGRvdXQuc3RyaXAoKQogICAgICAgIGlmIG5vdCBwaWQuaXNkaWdpdCgpIG9yIGludChwaWQpPD0wOnJhaXNlIFJ1bnRpbWVFcnJvcign5peg5rOV56Gu6K6k5bey5pyJ5ZCO56uv6L+b56iL77yM5pyq5YGc5q2i5pyN5YqhJykKICAgICAgICBpZiBoYXNobGliLnNoYTI1NihQYXRoKCcvcHJvYy8nK3BpZCsnL2V4ZScpLnJlYWRfYnl0ZXMoKSkuaGV4ZGlnZXN0KCkhPXN0YXRlLmdldCgnYmluYXJ5X3NoYTI1NicpOgogICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+W3suacieWQjuerr+WTiOW4jOS4juWuieijheiusOW9leS4jeS4gOiHtO+8jOacquWBnOatouacjeWKoScpCiAgICAgICAgcmV0dXJuIHBpZAogICAgcmV0dXJuIE5vbmUKCgpkZWYgY2hlY2tfaW5zdGFsbF9wb3J0cyhzZWxlY3RlZCxwaWQpOgogICAgZm9yIHByb3RvIGluIHNlbGVjdGVkOgogICAgICAgIHNvY2s9Jy1IbHVucCcgaWYgcHJvdG89PSdoeTInIGVsc2UgJy1IbHRucCcKICAgICAgICBsaW5lcz1ydW4oJ3NzJyxzb2NrLCdzcG9ydCA9IDonK3N0cihQUk9UT0NPTFNbcHJvdG9dWzFdKSkuc3Rkb3V0LnNwbGl0bGluZXMoKQogICAgICAgIGZvciBsaW5lIGluIGxpbmVzOgogICAgICAgICAgICBvd25lcnM9c2V0KHJlLmZpbmRhbGwocidwaWQ9KFxkKyknLGxpbmUpKQogICAgICAgICAgICBpZiBub3QgcGlkIG9yIG93bmVycyE9e3BpZH06CiAgICAgICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+aJgOmcgOerr+WPo+iiq+WFtuS7lui/m+eoi+WNoOeUqO+8jOWNj+iuru+8micrcHJvdG8rJ++8m+acquWBnOatouW3suacieacjeWKoScpCgoKZGVmIG1haW4oYXJndj1Ob25lKToKICAgIGFyZ3MgPSBwYXJzZXIoKS5wYXJzZV9hcmdzKGFyZ3YpCiAgICBpZiBvcy5nZXRldWlkKCkgIT0gMDogcmFpc2UgUnVudGltZUVycm9yKCfor7fkvb/nlKggcm9vdCDmiJYgc3VkbyDov5DooYwnKQogICAgb3MudW1hc2soMG8wNzcpCiAgICBpZiBhcmdzLnJlcG9ydF9maWxlIGFuZCBub3QgYXJncy5jaGVjazpyYWlzZSBWYWx1ZUVycm9yKCctLXJlcG9ydC1maWxlIOW/hemhu+S4jiAtLWNoZWNrIOS4gOi1t+S9v+eUqCcpCiAgICBpZiBhcmdzLnBsYW46CiAgICAgICAgc2VsZWN0ZWQgPSAoYXJncy5wcm90b2NvbHMgb3IgJ3ZsZXNzLGh5MicpLnNwbGl0KCcsJykKICAgICAgICBpZiBhbnkocCBub3QgaW4gUFJPVE9DT0xTIGZvciBwIGluIHNlbGVjdGVkKTogcmFpc2UgVmFsdWVFcnJvcign5pSv5oyB55qE5Y2P6K6u77yadmxlc3MsaHkyLGFueXRscycpCiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyh7J3Byb3RvY29scyc6IHNlbGVjdGVkLCAncmVzb3VyY2VzJzogcmVzb3VyY2VzKCksICdwdWJsaWNhdGlvbic6ICfpu5jorqTlronoo4XlkI7nm7TmjqXlnKjpnaLmnb/mmL7npLrvvIzmupDnq5noh6rliqjmjqXlhaXosIPluqbjgIHoioLngrnliIbnu4Tlkoznm5HmjqfvvJstLW5vLXB1Ymxpc2gg5L+d5oyB6ZqQ6JePJ30sIGVuc3VyZV9hc2NpaT1GYWxzZSwgaW5kZW50PTIpKQogICAgICAgIHJldHVybgogICAgaWYgYXJncy5zdGF0dXMgb3IgYXJncy5jaGVjazoKICAgICAgICBpZiBhcmdzLnN0YXR1cyBhbmQgYXJncy5jaGVjazpyYWlzZSBWYWx1ZUVycm9yKCctLXN0YXR1cyDlkowgLS1jaGVjayDlj6rog73pgInmi6nkuIDkuKonKQogICAgICAgIHN0YXRlX3BhdGg9Uk9PVC8nc3RhdGUuanNvbicKICAgICAgICBzdGF0ZT1qc29uLmxvYWRzKHN0YXRlX3BhdGgucmVhZF90ZXh0KCkpIGlmIHN0YXRlX3BhdGguZXhpc3RzKCkgZWxzZSB7fQogICAgICAgIGlmIGFyZ3Muc3RhdHVzOgogICAgICAgICAgICBwcmludChqc29uLmR1bXBzKHtrOnN0YXRlLmdldChrKSBmb3IgayBpbiAoJ2hvc3QnLCduYW1lJywncHJvdG9jb2xzJywnaWRzJywncGhhc2UnLCdwdWJsaXNoZWQnLCdtb25pdG9yJywnbm9kZV9ncm91cCcsJ3Jlc291cmNlcycpfSxlbnN1cmVfYXNjaWk9RmFsc2UsaW5kZW50PTIpKQogICAgICAgICAgICByZXR1cm4KICAgICAgICByZXBvcnQ9ZGlhZ25vc2Uoc3RhdGUpCiAgICAgICAgaWYgYXJncy5yZXBvcnRfZmlsZToKICAgICAgICAgICAgZXhwb3J0X3JlcG9ydChhcmdzLnJlcG9ydF9maWxlLHJlcG9ydCkKICAgICAgICBmb3IgaXRlbSBpbiByZXBvcnRbJ2NoZWNrcyddOgogICAgICAgICAgICBwcmludCgoJ+mAmui/hycgaWYgaXRlbVsncGFzc2VkJ10gZWxzZSAn5aSx6LSlJykrJ++8micraXRlbVsnbGFiZWwnXSkKICAgICAgICBwcmludCgn5pys5py66Ieq5qOA5LiN5Luj6KGo5YWs572RIFRDUC9VRFAg5oiW6ZuG5Lit55uR5o6n6aqM5pS26YCa6L+H44CCJykKICAgICAgICBpZiBub3QgcmVwb3J0WydwYXNzZWQnXTpyYWlzZSBSdW50aW1lRXJyb3IoJ+acrOacuuiHquajgOacqumAmui/h++8jOivt+aMieWksei0pemhueebruaOkuafpe+8m+acquS/ruaUueacjeWKoeaIlumFjee9ricpCiAgICAgICAgcmV0dXJuCiAgICBST09ULm1rZGlyKHBhcmVudHM9VHJ1ZSwgZXhpc3Rfb2s9VHJ1ZSwgbW9kZT0wbzcwMCkKICAgIGxvY2sgPSBvcGVuKFJPT1QgLyAnbG9jaycsICd3JykKICAgIHRyeTpmY250bC5mbG9jayhsb2NrLCBmY250bC5MT0NLX0VYIHwgZmNudGwuTE9DS19OQikKICAgIGV4Y2VwdCBCbG9ja2luZ0lPRXJyb3I6cmFpc2UgUnVudGltZUVycm9yKCflt7LmnInlronoo4Xku7vliqHmraPlnKjov5DooYzvvIzor7fli7/lkIzml7bmiafooYzvvJvnrYnlvoXlvZPliY3ku7vliqHnu5PmnZ/lkI7lho3nu63ot5EnKSBmcm9tIE5vbmUKICAgIHN0YXRlX3BhdGggPSBST09UIC8gJ3N0YXRlLmpzb24nCiAgICBzdGF0ZSA9IGpzb24ubG9hZHMoc3RhdGVfcGF0aC5yZWFkX3RleHQoKSkgaWYgc3RhdGVfcGF0aC5leGlzdHMoKSBlbHNlIHt9CiAgICBpZiBhcmdzLnJvbGxiYWNrOgogICAgICAgIHJvbGxiYWNrKHN0YXRlKTtyZXR1cm4KICAgIGlmIGFyZ3MucmV0dW5lOgogICAgICAgIHJldHVuZShzdGF0ZSk7cmV0dXJuCiAgICBpZiBhcmdzLmhpZGUgb3IgYXJncy5zaG93IG9yIGFyZ3MudW5pbnN0YWxsOgogICAgICAgIG1hbmFnZShhcmdzLHN0YXRlKTtyZXR1cm4KICAgIGRlZiB3YW50ZWQodmFsdWUpOgogICAgICAgIHJldHVybiBsaXN0KGRpY3QuZnJvbWtleXMoeC5zdHJpcCgpLmxvd2VyKCkgZm9yIHggaW4gdmFsdWUuc3BsaXQoJywnKSBpZiB4LnN0cmlwKCkpKQogICAgYWRkZWQ9W3ggZm9yIHggaW4gd2FudGVkKGFyZ3MucHJvdG9jb2xzKSBpZiB4IG5vdCBpbiBzdGF0ZS5nZXQoJ3Byb3RvY29scycsW10pXSBpZiBhcmdzLnByb3RvY29scyBhbmQgc3RhdGUuZ2V0KCdwcm90b2NvbHMnKSBlbHNlIFtdCiAgICBpZiBhZGRlZCBhbmQgc3RhdGUuZ2V0KCdwaGFzZScpIGluICgnaW5zdGFsbGVkJywncHVibGlzaGVkJyk6CiAgICAgICAgIyDov73liqDljY/orq7vvJrlt7LmnInpnaLmnb/ooYzkv53nlZnvvIzlj6rkuLrmlrDlop7ljY/orq7lu7rooYzvvIzph43lhpnphY3nva7jgIHph43lkK/lkI7nq6/vvIzlho3mmL7npLrlhajpg6jnur/ot6/jgIIKICAgICAgICBwcmludCgn6L+95Yqg5Y2P6K6u77yaJysnLCcuam9pbihhZGRlZCkrJ++8iOW3suaciSAnKycsJy5qb2luKHN0YXRlWydwcm90b2NvbHMnXSkrJyDkv53nlZnvvIknLGZsdXNoPVRydWUpCiAgICAgICAgc3RhdGVbJ3B1Ymxpc2gnXT1zdGF0ZS5nZXQoJ3B1Ymxpc2gnLFRydWUpIGlmIGFyZ3MucHVibGlzaCBpcyBOb25lIGVsc2UgYXJncy5wdWJsaXNoCiAgICAgICAgc3RhdGVbJ3B1Ymxpc2hlZCddPUZhbHNlICAjIFBlcnNpc3Qgb25seSBhZnRlciBwcmVmbGlnaHQgdmFsaWRhdGlvbiBiZWdpbnMuCiAgICBlbGlmIHN0YXRlLmdldCgncGhhc2UnKSBpbiAoJ2luc3RhbGxlZCcsJ3B1Ymxpc2hlZCcpOgogICAgICAgIGlmIHJ1bignc3lzdGVtY3RsJywnaXMtYWN0aXZlJywnLS1xdWlldCcsJ3doYWxlbm9kZS5zZXJ2aWNlJyxjaGVjaz1GYWxzZSkucmV0dXJuY29kZToKICAgICAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCfku7vliqHorrDlvZXlt7Llronoo4XvvIzkvYbmnI3liqHmsqHmnInov5DooYzvvJvor7fmo4Dmn6Ugam91cm5hbGN0bCAtdSB3aGFsZW5vZGXvvIzlho3miafooYwgLS1yb2xsYmFjayDlkI7nu63ot5EnKQogICAgICAgIHZlcmlmeV9zZXJ2aWNlKHN0YXRlKQogICAgICAgIGlmIGFyZ3MucHVibGlzaCBpcyBub3QgTm9uZTpzdGF0ZVsncHVibGlzaCddPWFyZ3MucHVibGlzaAogICAgICAgIGlmIHN0YXRlLmdldCgnbW9uaXRvcicpIGFuZCAoc3RhdGUuZ2V0KCdwdWJsaXNoZWQnKSBvciBub3Qgc3RhdGUuZ2V0KCdwdWJsaXNoJyxUcnVlKSk6CiAgICAgICAgICAgIGlmIGFyZ3Mubm9uX2ludGVyYWN0aXZlIG9yIG5vdCBvcy5pc2F0dHkoMCkgYW5kIG5vdCBQYXRoKCcvZGV2L3R0eScpLmV4aXN0cygpOgogICAgICAgICAgICAgICAgcHJpbnQoc3VtbWFyeShzdGF0ZSkpO3JldHVybgogICAgICAgICAgICB0cnk6bWFuYWdlKGFyZ3Msc3RhdGUpCiAgICAgICAgICAgIGV4Y2VwdCBSdW50aW1lRXJyb3IgYXMgZToKICAgICAgICAgICAgICAgIGlmICfmsqHmnInkuqTkupLnu4jnq68nIG5vdCBpbiBzdHIoZSk6cmFpc2UKICAgICAgICAgICAgICAgIHByaW50KHN1bW1hcnkoc3RhdGUpKQogICAgICAgICAgICByZXR1cm4KICAgICAgICBwcmVwYXJlX2Rvd25sb2FkX2F1dGgoYXJncykKICAgICAgICBmaW5pc2goYXJncyxzdGF0ZSk7cmV0dXJuCiAgICBydW5uaW5nX3BpZD1iYWNrZW5kX3ByZWZsaWdodChzdGF0ZSkKICAgIGlmIG5vdCBzdGF0ZSBhbmQgYW55KFBhdGgocCkuZXhpc3RzKCkgZm9yIHAgaW4gKHN0cihDT05GKSwnL2V0Yy9zeXN0ZW1kL3N5c3RlbS93aGFsZW5vZGUuc2VydmljZScsJy9ldGMvc3lzdGVtZC9zeXN0ZW0vd2hhbGVub2RlLWVncmVzcy5zZXJ2aWNlJywnL2V0Yy9zeXNjdGwuZC85MC13aGFsZW5vZGUuY29uZicsJy9ldGMvd2hhbGVub2RlLWVncmVzcy5uZnQnKSk6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCflj5HnjrDlt7LmnIkgV2hhbGVOb2RlIOaWh+S7tu+8jOivt+ajgOafpeWQjuWGjeWuieijhScpCiAgICBwcmludCgnV2hhbGVOb2RlIOS4reaWh+WuieijheWQkeWvvOOAguW3suacieWPguaVsOiHquWKqOmHh+eUqO+8jOWvhumSpemakOiXj+i+k+WFpeOAgicsZmx1c2g9VHJ1ZSkKICAgIHByZXBhcmVfZG93bmxvYWRfYXV0aChhcmdzKQogICAgd2l6YXJkKGFyZ3Msc3RhdGUpCiAgICBzZWxlY3RlZCA9IHdhbnRlZChhcmdzLnByb3RvY29scyBvciAnLCcuam9pbihzdGF0ZS5nZXQoJ3Byb3RvY29scycsIFsndmxlc3MnLCdoeTInXSkpKQogICAgaWYgc3RhdGUuZ2V0KCdwcm90b2NvbHMnKSBhbmQgc2V0KHN0YXRlWydwcm90b2NvbHMnXSk8PXNldChzZWxlY3RlZCk6CiAgICAgICAgc2VsZWN0ZWQ9c3RhdGVbJ3Byb3RvY29scyddK1t4IGZvciB4IGluIHNlbGVjdGVkIGlmIHggbm90IGluIHN0YXRlWydwcm90b2NvbHMnXV0KICAgIGlmIG5vdCBzZWxlY3RlZCBvciBhbnkocCBub3QgaW4gUFJPVE9DT0xTIGZvciBwIGluIHNlbGVjdGVkKTogcmFpc2UgVmFsdWVFcnJvcign5pSv5oyB55qE5Y2P6K6u77yadmxlc3MsaHkyLGFueXRscycpCiAgICBpZiBzdGF0ZS5nZXQoJ3Byb3RvY29scycpIGFuZCBzZWxlY3RlZFs6bGVuKHN0YXRlWydwcm90b2NvbHMnXSldICE9IHN0YXRlWydwcm90b2NvbHMnXTogcmFpc2UgVmFsdWVFcnJvcign5Y+q6IO96L+95Yqg5Y2P6K6u77yM5LiN6IO95Y675o6J5bey5pyJ5Y2P6K6u77yb5Y675o6J6K+35YWIIC0tdW5pbnN0YWxsJykKICAgIGZhY3RzID0gcmVzb3VyY2VzKCkKICAgIGZvciBuYW1lIGluICgnYXBpX3VybCcsJ2FkbWluX3VybCcsJ2JpbmFyeV91cmwnLCdiaW5hcnlfc2hhMjU2Jywnc291cmNlX2NvbW1pdCcsJ2hvc3QnLCduYW1lJywnc25pJyk6CiAgICAgICAgdmFsdWUgPSBnZXRhdHRyKGFyZ3MsbmFtZSkgb3Igc3RhdGUuZ2V0KG5hbWUpCiAgICAgICAgaWYgc3RhdGUuZ2V0KCdpZHMnKSBhbmQgc3RhdGUuZ2V0KG5hbWUpICE9IHZhbHVlOgogICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCflt7LliJvlu7roioLngrnnmoTnu63ot5HkuI3og73mm7TmlLkgLS0nK25hbWUucmVwbGFjZSgnXycsJy0nKSkKICAgICAgICBpZiB2YWx1ZTogc3RhdGVbbmFtZV0gPSB2YWx1ZQogICAgZm9yIG5hbWUgaW4gKCdhcGlfdXJsJywnYWRtaW5fdXJsJywnYmluYXJ5X3VybCcpOgogICAgICAgIGlmIG5vdCBzdGF0ZS5nZXQobmFtZSk6IHJhaXNlIFZhbHVlRXJyb3IoJ+e8uuWwkeW/heWhq+WPguaVsCAtLScgKyBuYW1lLnJlcGxhY2UoJ18nLCctJykpCiAgICAgICAgaHR0cHMoc3RhdGVbbmFtZV0pCiAgICBpZiBub3QgcmUuZnVsbG1hdGNoKCdbYS1mQS1GMC05XXs2NH0nLHN0YXRlLmdldCgnYmluYXJ5X3NoYTI1NicsJycpKTogcmFpc2UgVmFsdWVFcnJvcign6K+36YCa6L+HIC0tYmluYXJ5LXNoYTI1NiDmj5Dkvpvop6PljovlkI7lj6/miafooYzmlofku7bnmoQgU0hBMjU2JykKICAgIHN0YXRlWydiaW5hcnlfc2hhMjU2J109c3RhdGVbJ2JpbmFyeV9zaGEyNTYnXS5sb3dlcigpCiAgICBpZiBub3QgcmUuZnVsbG1hdGNoKCdbYS1mMC05XXs0MH0nLHN0YXRlLmdldCgnc291cmNlX2NvbW1pdCcsJycpKTogcmFpc2UgVmFsdWVFcnJvcign6K+36YCa6L+HIC0tc291cmNlLWNvbW1pdCDmj5DkvpvlrozmlbTnmoQgNDAg5L2N5rqQ56CB5o+Q5Lqk5Y+3JykKICAgIGlmIHN0YXRlLmdldCgnc25pJykgYW5kIG5vdCByZS5mdWxsbWF0Y2gocidbYS16QS1aMC05XVthLXpBLVowLTkuLV17MSwyNTF9W2EtekEtWjAtOV0nLHN0YXRlWydzbmknXSk6IHJhaXNlIFZhbHVlRXJyb3IoJ+ivt+mAmui/hyAtLXNuaSDmj5Dkvpvlt7LmtYvor5Xlj6/nlKjnmoQgVExTIOWfn+WQjScpCiAgICBpZiBub3Qgc3RhdGUuZ2V0KCdob3N0Jyk6CiAgICAgICAgZ2VvID0gaXB2NF9yZXF1ZXN0KCdodHRwczovL2lwd2hvLmlzLycpCiAgICAgICAgaWYgZ2VvLmdldCgnc3VjY2VzcycpIGlzIG5vdCBUcnVlOiByYWlzZSBSdW50aW1lRXJyb3IoJ+WcsOWMuuivhuWIq+Wksei0pe+8jOivt+aPkOS+myAtLWhvc3Qg5ZKMIC0tbmFtZScpCiAgICAgICAgc3RhdGVbJ2hvc3QnXSA9IHN0cihpcGFkZHJlc3MuSVB2NEFkZHJlc3MoZ2VvWydpcCddKSkKICAgICAgICBpZiBub3Qgc3RhdGUuZ2V0KCduYW1lJyk6CiAgICAgICAgICAgICMg57q/6Lev5ZCN56ew5LiN5YeG5bimIElQ77yIb3duZXIgMjAyNi0xMS0wN++8ieOAguWFiOiusOWcsOWMuu+8jOe8luWPt+etieaLv+WIsOmdouadv+a4heWNleWQjuWGjeWumuOAggogICAgICAgICAgICBzdGF0ZVsnbmFtZSddID0gc3RyKGdlb1snY291bnRyeV9jb2RlJ10pICsgJyAnICsgc3RyKGdlb1snY2l0eSddKTsgc3RhdGVbJ25hbWVfYXV0byddID0gVHJ1ZQogICAgc3RhdGVbJ2hvc3QnXSA9IHN0cihpcGFkZHJlc3MuSVB2NEFkZHJlc3Moc3RhdGVbJ2hvc3QnXSkpCiAgICBpZiBub3Qgc3RhdGUuZ2V0KCduYW1lJyk6CiAgICAgICAgZ2VvID0gaXB2NF9yZXF1ZXN0KCdodHRwczovL2lwd2hvLmlzLycgKyBzdGF0ZVsnaG9zdCddKQogICAgICAgIGlmIGdlby5nZXQoJ3N1Y2Nlc3MnKSBpcyBub3QgVHJ1ZTogcmFpc2UgUnVudGltZUVycm9yKCflnLDljLror4bliKvlpLHotKXvvIzor7fmj5DkvpsgLS1uYW1lJykKICAgICAgICBzdGF0ZVsnbmFtZSddID0gc3RyKGdlb1snY291bnRyeV9jb2RlJ10pICsgJyAnICsgc3RyKGdlb1snY2l0eSddKTsgc3RhdGVbJ25hbWVfYXV0byddID0gVHJ1ZQogICAgaWYgTkFNRV9JUC5zZWFyY2goc3RhdGVbJ25hbWUnXSkgYW5kIG5vdCBzdGF0ZS5nZXQoJ2lkcycpOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoJ+iKgueCueWQjeensOS4jeiDveWMheWQqyBJUCDlnLDlnYDvvJonK3N0YXRlWyduYW1lJ10pCiAgICBpZiBsZW4oc3RhdGVbJ25hbWUnXSkgPiA4MCBvciBhbnkob3JkKGMpPDMyIGZvciBjIGluIHN0YXRlWyduYW1lJ10pOiByYWlzZSBWYWx1ZUVycm9yKCfoioLngrnlkI3np7Dml6DmlYgnKQogICAgZGVmIGlkcyh2YWx1ZSk6CiAgICAgICAgb3V0ID0gW2ludCh4KSBmb3IgeCBpbiB2YWx1ZS5zcGxpdCgnLCcpIGlmIHhdCiAgICAgICAgaWYgYW55KHg8MSBmb3IgeCBpbiBvdXQpOiByYWlzZSBWYWx1ZUVycm9yKCdJRCDlv4XpobvmmK/mraPmlbTmlbAnKQogICAgICAgIHJldHVybiBvdXQKICAgIGdyb3VwcyA9IGlkcyhhcmdzLmdyb3VwX2lkcykgaWYgYXJncy5ncm91cF9pZHMgaXMgbm90IE5vbmUgZWxzZSBzdGF0ZS5nZXQoJ2dyb3VwcycsWzFdKQogICAgcm91dGVzID0gaWRzKGFyZ3Mucm91dGVfaWRzKSBpZiBhcmdzLnJvdXRlX2lkcyBpcyBub3QgTm9uZSBlbHNlIHN0YXRlLmdldCgncm91dGVzJyxbXSkKICAgIGlmIG5vdCBncm91cHM6IHJhaXNlIFZhbHVlRXJyb3IoJ+iHs+WwkemcgOimgeS4gOS4qumdouadv+adg+mZkOe7hCcpCiAgICBpZiBzdGF0ZS5nZXQoJ2lkcycpIGFuZCAoZ3JvdXBzICE9IHN0YXRlLmdldCgnZ3JvdXBzJykgb3Igcm91dGVzICE9IHN0YXRlLmdldCgncm91dGVzJykpOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoJ+e7rei3keW/hemhu+S/neeVmeWOn+mdouadv+adg+mZkOe7hOWSjOi3r+eUsee7hCcpCiAgICBzdGF0ZS51cGRhdGUoZ3JvdXBzPWdyb3Vwcyxyb3V0ZXM9cm91dGVzKQogICAgc3RhdGVbJ25vZGVfZ3JvdXAnXT1yZXN1bWVfZ3JvdXAoYXJncy5ub2RlX2dyb3VwLHN0YXRlKQogICAgc3RhdGVbJ3B1Ymxpc2gnXT1hcmdzLnB1Ymxpc2ggaWYgYXJncy5wdWJsaXNoIGlzIG5vdCBOb25lIGVsc2Ugc3RhdGUuZ2V0KCdwdWJsaXNoJyxUcnVlKQogICAgZGVmIGNyZWRlbnRpYWwodmFsdWUsIHBhdGgsIGxhYmVsKToKICAgICAgICByZXR1cm4gc2VjcmV0KGFyZ3MsdmFsdWUscGF0aCxsYWJlbCkKICAgIGlmIG5vdCBhcmdzLmFwaV9rZXkgYW5kIG5vdCBhcmdzLmFwaV9rZXlfZmlsZSBhbmQgKENPTkYvJ2NvbmZpZy5qc29uJykuZXhpc3RzKCk6CiAgICAgICAgcHJldmlvdXM9anNvbi5sb2FkcygoQ09ORi8nY29uZmlnLmpzb24nKS5yZWFkX3RleHQoKSkKICAgICAgICBub2Rlcz1wcmV2aW91cy5nZXQoJ05vZGVzJyxbXSkKICAgICAgICBpZiBub2RlcyBhbmQgYWxsKG4uZ2V0KCdBcGlIb3N0Jyk9PXN0YXRlWydhcGlfdXJsJ10gZm9yIG4gaW4gbm9kZXMpOmFyZ3MuYXBpX2tleT1ub2Rlc1swXS5nZXQoJ0FwaUtleScpCiAgICBhcGlfa2V5ID0gY3JlZGVudGlhbChhcmdzLmFwaV9rZXksYXJncy5hcGlfa2V5X2ZpbGUsJ+ivt+i+k+WFpeiKgueCuSBBUEkg5a+G6ZKl77yI6ZqQ6JeP6L6T5YWl77yJ77yaJykKICAgIGFkbWluID0gY3JlZGVudGlhbChhcmdzLmFkbWluX3Rva2VuLGFyZ3MuYWRtaW5fdG9rZW5fZmlsZSwn6K+36L6T5YWl6Z2i5p2/566h55CG5ZGY5o6I5p2D5YC877yI6ZqQ6JeP6L6T5YWl77yM5LiN5L+d5a2Y77yJ77yaJykKICAgIGlmIG5vdCBhcGlfa2V5IG9yIG5vdCBhZG1pbjogcmFpc2UgVmFsdWVFcnJvcign5Yet5o2u5LiN6IO95Li656m6JykKICAgIHN0YXRlLnVwZGF0ZShwcm90b2NvbHM9c2VsZWN0ZWQsIHJlc291cmNlcz1mYWN0cykKICAgIHN0YXRlLnNldGRlZmF1bHQoJ2lkcycse30pCiAgICBzdGF0ZS5zZXRkZWZhdWx0KCdub25jZScsc2VjcmV0cy50b2tlbl9oZXgoNikpCiAgICBkZWYgc2F2ZShwaGFzZSk6CiAgICAgICAgc3RhdGVbJ3BoYXNlJ10gPSBwaGFzZQogICAgICAgIGF0b21pYyhzdGF0ZV9wYXRoLGpzb24uZHVtcHMoc3RhdGUsaW5kZW50PTIpKQogICAgc2F2ZSgncHJlZmxpZ2h0JykKICAgIGRlcGVuZGVuY3lfY2hlY2soKQogICAgIyBPd25lZCBsaXN0ZW5lcnMgcmVtYWluIG9ubGluZSBkdXJpbmcgcHJlZmxpZ2h0OyBmb3JlaWduIG93bmVycyBzdGlsbCBmYWlsLgogICAgY2hlY2tfaW5zdGFsbF9wb3J0cyhzZWxlY3RlZCxydW5uaW5nX3BpZCkKICAgIGFsbF9ub2RlcyA9IHJvd3MocmVxdWVzdChzdGF0ZVsnYWRtaW5fdXJsJ10rJy9zZXJ2ZXIvbWFuYWdlL2dldE5vZGVzJyxhZG1pbikpCiAgICBzdGF0ZVsnbmFtZSddPXNldHRsZV9uYW1lKHN0YXRlLGFsbF9ub2Rlcyk7c2F2ZSgncHJlZmxpZ2h0JykKICAgIGlmIG5vdCBzdGF0ZS5nZXQoJ25vZGVfZ3JvdXAnKToKICAgICAgICBzdGF0ZVsnbm9kZV9ncm91cCddPXJlc3VtZV9ncm91cChhcmdzLm5vZGVfZ3JvdXAsc3RhdGUsYWxsX25vZGVzKQogICAgICAgIHNhdmUoJ3ByZWZsaWdodCcpCiAgICBzdGF0ZS5zZXRkZWZhdWx0KCdzbmlzJyx7fSkKICAgIHVzZWQ9c25pX3VzYWdlKGFsbF9ub2RlcykKICAgIHBvb2w9bG9hZF9zbmlfcG9vbChhcmdzLHN0YXRlKSBpZiBub3Qgc3RhdGUuZ2V0KCdzbmknKSBhbmQgYW55KHAgbm90IGluIHN0YXRlWydzbmlzJ10gZm9yIHAgaW4gc2VsZWN0ZWQpIGVsc2UgW10KICAgIGZvciBwcm90byBpbiBzZWxlY3RlZDoKICAgICAgICBpZiBwcm90byBub3QgaW4gc3RhdGVbJ3NuaXMnXToKICAgICAgICAgICAgc3RhdGVbJ3NuaXMnXVtwcm90b109c3RhdGUuZ2V0KCdzbmknKSBvciBjaG9vc2Vfc25pKHVzZWQsdGxzMTM9cHJvdG89PSd2bGVzcycscG9vbD1wb29sKQogICAgICAgICAgICB1c2VkW3N0YXRlWydzbmlzJ11bcHJvdG9dLmxvd2VyKCkucnN0cmlwKCcuJyldKz0xO3NhdmUoJ3ByZWZsaWdodCcpCiAgICBwcmludCgn5ZCO5Y+w6L+e5o6l6YCa6L+H77yb5q2j5Zyo5qCh6aqM5ZCO56uv5Y+R5biD5YyF4oCmJyxmbHVzaD1UcnVlKQogICAgcmVsZWFzZXMgPSBQYXRoKCcvb3B0L3doYWxlbm9kZS9yZWxlYXNlcycpOyByZWxlYXNlcy5ta2RpcihwYXJlbnRzPVRydWUsZXhpc3Rfb2s9VHJ1ZSkKICAgIHJlbGVhc2VzLnBhcmVudC5jaG1vZCgwbzc1NSk7cmVsZWFzZXMuY2htb2QoMG83NTUpCiAgICBiaW5hcnkgPSByZWxlYXNlcyAvIHN0YXRlWydiaW5hcnlfc2hhMjU2J10KICAgIGlmIG5vdCBiaW5hcnkuZXhpc3RzKCk6CiAgICAgICAgaWYgc2h1dGlsLmRpc2tfdXNhZ2Uoc3RyKFJPT1QpKS5mcmVlPDUxMioxMDI0KjEwMjQ6cmFpc2UgUnVudGltZUVycm9yKCflronoo4XliIbljLroh7PlsJHpnIDopoEgNTEyIE1pQiDlj6/nlKjnqbrpl7QnKQogICAgICAgIHdpdGggdGVtcGZpbGUuVGVtcG9yYXJ5RGlyZWN0b3J5KGRpcj1zdHIoUk9PVCkpIGFzIHRlbXA6CiAgICAgICAgICAgIGFyY2hpdmUgPSBQYXRoKHRlbXApLydyZWxlYXNlLmd6JwogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBhdXRoPWRvd25sb2FkX2F1dGgoYXJncyxzdGF0ZVsnYmluYXJ5X3VybCddLHN0YXRlLmdldCgncmVsZWFzZV9tYW5pZmVzdCcpIG9yIHN0YXRlWydiaW5hcnlfdXJsJ10pCiAgICAgICAgICAgICAgICByZXE9dXJsbGliLnJlcXVlc3QuUmVxdWVzdChzdGF0ZVsnYmluYXJ5X3VybCddLGhlYWRlcnM9eydBdXRob3JpemF0aW9uJzphdXRofSBpZiBhdXRoIGVsc2Uge30pCiAgICAgICAgICAgICAgICB3aXRoIHVybGxpYi5yZXF1ZXN0LmJ1aWxkX29wZW5lcihOb1JlZGlyZWN0KCkpLm9wZW4ocmVxLHRpbWVvdXQ9MTIwKSBhcyBzb3VyY2UsIGFyY2hpdmUub3Blbignd2InKSBhcyBvdXQ6CiAgICAgICAgICAgICAgICAgICAgYm91bmRlZF9jb3B5KHNvdXJjZSxvdXQsMTI4KjEwMjQqMTAyNCkKICAgICAgICAgICAgZXhjZXB0ICh1cmxsaWIuZXJyb3IuVVJMRXJyb3IsT1NFcnJvcik6IHJhaXNlIFJ1bnRpbWVFcnJvcign5Y+R5biD5YyF5LiL6L295aSx6LSlJykgZnJvbSBOb25lCiAgICAgICAgICAgIGNhbmRpZGF0ZT1QYXRoKHRlbXApLyd3aGFsZW5vZGUnCiAgICAgICAgICAgIHdpdGggZ3ppcC5vcGVuKGFyY2hpdmUsJ3JiJykgYXMgc291cmNlLCBjYW5kaWRhdGUub3Blbignd2InKSBhcyBvdXQ6Ym91bmRlZF9jb3B5KHNvdXJjZSxvdXQsMjU2KjEwMjQqMTAyNCkKICAgICAgICAgICAgaWYgaGFzaGxpYi5zaGEyNTYoY2FuZGlkYXRlLnJlYWRfYnl0ZXMoKSkuaGV4ZGlnZXN0KCkhPXN0YXRlWydiaW5hcnlfc2hhMjU2J106CiAgICAgICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+WPkeW4g+WMhSBTSEEyNTYg5qCh6aqM5aSx6LSlJykKICAgICAgICAgICAgY2FuZGlkYXRlLmNobW9kKDBvNzU1KQogICAgICAgICAgICBpbmZvPWpzb24ubG9hZHMocnVuKHN0cihjYW5kaWRhdGUpLCd2ZXJzaW9uJywnLS1qc29uJykuc3Rkb3V0KQogICAgICAgICAgICBpZiBpbmZvLmdldCgncHJvZHVjdCcpIT0nV2hhbGVOb2RlJyBvciBpbmZvLmdldCgnY29tbWl0JykhPXN0YXRlWydzb3VyY2VfY29tbWl0J11bOjEyXSBvciBpbmZvLmdldCgncHJvZmlsZScpIT0nc2luZy1vd25lZCc6CiAgICAgICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ1doYWxlTm9kZSDkuqflk4HmiJbmnoTlu7rmnaXmupDmoKHpqozlpLHotKUnKQogICAgICAgICAgICBmZCxzdGFnZWQ9dGVtcGZpbGUubWtzdGVtcChkaXI9c3RyKHJlbGVhc2VzKSxwcmVmaXg9Jy5jYW5kaWRhdGUtJykKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgd2l0aCBvcy5mZG9wZW4oZmQsJ3diJykgYXMgb3V0LCBjYW5kaWRhdGUub3BlbigncmInKSBhcyBzb3VyY2U6CiAgICAgICAgICAgICAgICAgICAgc2h1dGlsLmNvcHlmaWxlb2JqKHNvdXJjZSxvdXQpO291dC5mbHVzaCgpO29zLmZzeW5jKG91dC5maWxlbm8oKSkKICAgICAgICAgICAgICAgIG9zLmNobW9kKHN0YWdlZCwwbzc1NSk7b3MucmVwbGFjZShzdGFnZWQsYmluYXJ5KQogICAgICAgICAgICBmaW5hbGx5OgogICAgICAgICAgICAgICAgaWYgb3MucGF0aC5leGlzdHMoc3RhZ2VkKTpvcy51bmxpbmsoc3RhZ2VkKQogICAgaWYgaGFzaGxpYi5zaGEyNTYoYmluYXJ5LnJlYWRfYnl0ZXMoKSkuaGV4ZGlnZXN0KCkhPXN0YXRlWydiaW5hcnlfc2hhMjU2J106IHJhaXNlIFJ1bnRpbWVFcnJvcign5bey5LiL6L295Y+v5omn6KGM5paH5Lu255qEIFNIQTI1NiDkuI3ljLnphY0nKQogICAgZm9yIHByb3RvIGluIHNlbGVjdGVkOgogICAgICAgIHR5cCxwb3J0PVBST1RPQ09MU1twcm90b10KICAgICAgICBuYW1lPXN0YXRlWyduYW1lJ10rJyDCtyAnK3Byb3RvLnVwcGVyKCkKICAgICAgICBtYXRjaGVzPVt4IGZvciB4IGluIGFsbF9ub2RlcyBpZiB4LmdldCgndHlwZScpPT10eXAgYW5kIHguZ2V0KCduYW1lJyk9PW5hbWVdCiAgICAgICAgaWYgcHJvdG8gaW4gc3RhdGVbJ2lkcyddOgogICAgICAgICAgICBtYXRjaGVzPVt4IGZvciB4IGluIGFsbF9ub2RlcyBpZiB4LmdldCgndHlwZScpPT10eXAgYW5kIGludCh4WydpZCddKT09c3RhdGVbJ2lkcyddW3Byb3RvXV0KICAgICAgICAjIOS7u+S9leWNj+iuruihqOmHjOmHjeWQjemDveS8muiuqee9keWFs+aVtOS7veiuoumYhSA0MDA477yM5omA5Lul6Leo6KGo5qOA5p+l44CCCiAgICAgICAgZWxpZiBhbnkoeC5nZXQoJ25hbWUnKT09bmFtZSBhbmQgc3RhdGVbJ25vbmNlJ10gbm90IGluICh4LmdldCgndGFncycpIG9yIFtdKSBmb3IgeCBpbiBhbGxfbm9kZXMpOgogICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+mdouadv+W3suacieWQjOWQjeiKgueCue+8iOS7u+aEj+WNj+iuru+8ie+8jOacquaOpeeuoeaIluimhueblu+8micrbmFtZSkKICAgICAgICBpZiBub3QgbWF0Y2hlczoKICAgICAgICAgICAgdGFncz1bTUFSSyxzdGF0ZVsnbm9uY2UnXSwnd24tZ3JvdXA6JytzdGF0ZVsnbm9kZV9ncm91cCddLCd3bi1jcHU6JytzdHIoZmFjdHNbJ2NwdXMnXSksCiAgICAgICAgICAgICAgICAgICd3bi1zc2g6JytzdHIoc3NoX3BvcnQoKSksJ3duLW5hbWU6JytzdGF0ZVsnbmFtZSddXQogICAgICAgICAgICBwYXlsb2FkPXsnbmFtZSc6bmFtZSwnaG9zdCc6c3RhdGVbJ2hvc3QnXSwncG9ydCc6cG9ydCwnc2VydmVyX3BvcnQnOnBvcnQsJ2dyb3VwX2lkJzpncm91cHMsJ3JvdXRlX2lkJzpyb3V0ZXMsJ3JhdGUnOjEsJ3Nob3cnOjAsJ3RhZ3MnOnRhZ3N9CiAgICAgICAgICAgIGlmIHByb3RvPT0ndmxlc3MnOnBheWxvYWQudXBkYXRlKHRscz0yLG5ldHdvcms9J3RjcCcsZmxvdz0neHRscy1ycHJ4LXZpc2lvbicsZW5jcnlwdGlvbj0nbm9uZScsdGxzX3NldHRpbmdzPXsnc2VydmVyX25hbWUnOnN0YXRlWydzbmlzJ11bcHJvdG9dLCdkZXN0JzpzdGF0ZVsnc25pcyddW3Byb3RvXSwnc2VydmVyX3BvcnQnOic0NDMnLCdjZXJ0X21vZGUnOidub25lJywnYWxsb3dfaW5zZWN1cmUnOicwJywncmVqZWN0X3Vua25vd25fc25pJzonMCd9KQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgcGF5bG9hZC51cGRhdGUoc2VydmVyX25hbWU9c3RhdGVbJ3NuaXMnXVtwcm90b10saW5zZWN1cmU9MSkKICAgICAgICAgICAgICAgIGlmIHByb3RvPT0naHkyJzpwYXlsb2FkLnVwZGF0ZSh2ZXJzaW9uPTIsb2Jmcz0nc2FsYW1hbmRlcicsb2Jmc19wYXNzd29yZD1zZWNyZXRzLnRva2VuX2hleCgxNiksdXBfbWJwcz0wLGRvd25fbWJwcz0wKQogICAgICAgICAgICAjIEEgdGltZWQtb3V0IHdyaXRlIGlzIG5ldmVyIHJldHJpZWQgaGVyZTsgbmV4dCBydW4gcmVjb25jaWxlcyBpdHMgcGVyc2lzdGVkIHRhZy4KICAgICAgICAgICAgcmVzdWx0PXJlcXVlc3Qoc3RhdGVbJ2FkbWluX3VybCddKycvc2VydmVyLycrdHlwKycvc2F2ZScsYWRtaW4scGF5bG9hZCkKICAgICAgICAgICAgaWYgcmVzdWx0LmdldCgnZGF0YScpIGlzIG5vdCBUcnVlOnJhaXNlIFJ1bnRpbWVFcnJvcign6Z2i5p2/5pyq56Gu6K6k6IqC54K55Yib5bu65oiQ5YqfJykKICAgICAgICAgICAgYWxsX25vZGVzPXJvd3MocmVxdWVzdChzdGF0ZVsnYWRtaW5fdXJsJ10rJy9zZXJ2ZXIvbWFuYWdlL2dldE5vZGVzJyxhZG1pbikpCiAgICAgICAgICAgIG1hdGNoZXM9W3ggZm9yIHggaW4gYWxsX25vZGVzIGlmIHguZ2V0KCd0eXBlJyk9PXR5cCBhbmQgeC5nZXQoJ25hbWUnKT09bmFtZSBhbmQgc3RhdGVbJ25vbmNlJ10gaW4gKHguZ2V0KCd0YWdzJykgb3IgW10pXQogICAgICAgICMg5paw5bu655qE6KGM5b+F6aG75LuN5piv6ZqQ6JeP77yb6L+95Yqg5Y2P6K6u5pe277yM5bey5Y+R5biD55qE6ICB6KGM5L+d5oyB5pi+56S644CCCiAgICAgICAgaWYgbGVuKG1hdGNoZXMpIT0xIG9yIG1hdGNoZXNbMF0uZ2V0KCdob3N0JykhPXN0YXRlWydob3N0J10gb3IgKHByb3RvIG5vdCBpbiBzdGF0ZVsnaWRzJ10gYW5kIGludChtYXRjaGVzWzBdLmdldCgnc2hvdycsMCkpIT0wKSBvciBzdGF0ZVsnbm9uY2UnXSBub3QgaW4gKG1hdGNoZXNbMF0uZ2V0KCd0YWdzJykgb3IgW10pOgogICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+mdouadv+iKgueCueaguOWvueWksei0pe+8jOaWsOW7uuiKgueCueS7jeS/neaMgemakOiXjycpCiAgICAgICAgaWYgaW50KG1hdGNoZXNbMF0uZ2V0KCdzZXJ2ZXJfcG9ydCcsMCkpIT1wb3J0OnJhaXNlIFJ1bnRpbWVFcnJvcign6Z2i5p2/6IqC54K556uv5Y+j5LiO5Lu75Yqh5LiN5LiA6Ie077yM5YGc5q2i57ut6LeRJykKICAgICAgICBzdGF0ZVsnaWRzJ11bcHJvdG9dPWludChtYXRjaGVzWzBdWydpZCddKTtzYXZlKCdwYW5lbCcpCiAgICAgICAgcHJpbnQoJ+mdouadv+iKgueCueW3suaguOWvue+8micrcHJvdG8rJyAjJytzdHIoc3RhdGVbJ2lkcyddW3Byb3RvXSksZmx1c2g9VHJ1ZSkKICAgIGV4aXN0cz1ydW4oJ25mdCcsJ2xpc3QnLCd0YWJsZScsJ2luZXQnLCd3aGFsZW5vZGVfZWdyZXNzJyxjaGVjaz1GYWxzZSkucmV0dXJuY29kZT09MAogICAgaWYgZXhpc3RzIGFuZCBub3Qgc3RhdGUuZ2V0KCdvd25zX2VncmVzcycpOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcign5Y+R546w6Z2e5pys5Lu75Yqh55qE5Ye65Y+j6KeE5YiZ6KGo77yM6K+35YWI5qOA5p+lJykKICAgIGlmIHJ1bignaWQnLCctdScsJ3doYWxlbm9kZScsY2hlY2s9RmFsc2UpLnJldHVybmNvZGU6CiAgICAgICAgcnVuKCd1c2VyYWRkJywnLS1zeXN0ZW0nLCctLWhvbWUtZGlyJyxzdHIoQ09ORiksJy0tc2hlbGwnLCcvdXNyL3NiaW4vbm9sb2dpbicsJ3doYWxlbm9kZScpCiAgICB1aWQ9aW50KHJ1bignaWQnLCctdScsJ3doYWxlbm9kZScpLnN0ZG91dCkKICAgIENPTkYubWtkaXIobW9kZT0wbzcwMCxwYXJlbnRzPVRydWUsZXhpc3Rfb2s9VHJ1ZSkKICAgIG5vZGVzPVtdCiAgICBmb3IgcHJvdG8gaW4gc2VsZWN0ZWQ6CiAgICAgICAgdHlwPSdoeXN0ZXJpYTInIGlmIHByb3RvPT0naHkyJyBlbHNlIHByb3RvCiAgICAgICAgbm9kZXMuYXBwZW5kKHsnQ29yZSc6J3NpbmcnLCdBcGlIb3N0JzpzdGF0ZVsnYXBpX3VybCddLCdBcGlLZXknOmFwaV9rZXksJ05vZGVJRCc6c3RhdGVbJ2lkcyddW3Byb3RvXSwnTm9kZVR5cGUnOnR5cCwnVGltZW91dCc6MTgwLCdMaXN0ZW5JUCc6JzAuMC4wLjAnLCdTZW5kSVAnOicwLjAuMC4wJywnQ2VydENvbmZpZyc6eydDZXJ0TW9kZSc6J3NlbGYnLCdDZXJ0RG9tYWluJzpzdGF0ZVsnc25pcyddW3Byb3RvXSwnQ2VydEZpbGUnOnN0cihDT05GLyhwcm90bysnLmNlcicpKSwnS2V5RmlsZSc6c3RyKENPTkYvKHByb3RvKycua2V5JykpfX0pCiAgICBjb25maWc9eydMb2cnOnsnTGV2ZWwnOid3YXJuJywnT3V0cHV0JzonJ30sJ0NvcmVzJzpbeydUeXBlJzonc2luZycsJ0xvZyc6eydMZXZlbCc6J3dhcm4nfSwnT3JpZ2luYWxQYXRoJzpzdHIoQ09ORi8nc2luZ19vcmlnaW5hbC5qc29uJyl9XSwnTm9kZXMnOm5vZGVzfQogICAgIyBPbmx5IHN0b3Agb25jZSBhbGwgbmV0d29yay9kb3dubG9hZC9wYW5lbCBwcmVmbGlnaHQgaGFzIHN1Y2NlZWRlZC4KICAgIGNoZWNrX2luc3RhbGxfcG9ydHMoc2VsZWN0ZWQscnVubmluZ19waWQpCiAgICBpZiBzdGF0ZS5nZXQoJ293bnNfc2VydmljZScpOgogICAgICAgIHJ1bignc3lzdGVtY3RsJywnc3RvcCcsJ3doYWxlbm9kZS5zZXJ2aWNlJykKICAgIGF0b21pYyhDT05GLydjb25maWcuanNvbicsanNvbi5kdW1wcyhjb25maWcpKQogICAgYXRvbWljKENPTkYvJ3Npbmdfb3JpZ2luYWwuanNvbicsanNvbi5kdW1wcyh7J3JvdXRlJzp7J3J1bGVzJzpbXX19KSkKICAgIHJ1bignY2hvd24nLCctUicsJ3doYWxlbm9kZTp3aGFsZW5vZGUnLHN0cihDT05GKSk7Q09ORi5jaG1vZCgwbzcwMCkKICAgICMgT3duIG9ubHkgdGhpcyB0YWJsZS4gSVB2NiBtYW5hZ2VtZW50IGFuZCBvdGhlciBzZXJ2aWNlcyBhcmUgdW5hZmZlY3RlZC4KICAgIHRhYmxlPSd0YWJsZSBpbmV0IHdoYWxlbm9kZV9lZ3Jlc3Mge1xuIGNoYWluIG91dHB1dCB7XG4gIHR5cGUgZmlsdGVyIGhvb2sgb3V0cHV0IHByaW9yaXR5IDA7IHBvbGljeSBhY2NlcHQ7XG4gIG1ldGEgc2t1aWQgJytzdHIodWlkKSsnIG1ldGEgbmZwcm90byBpcHY2IGNvdW50ZXIgcmVqZWN0XG4gfVxufVxuJwogICAgbmZ0PVBhdGgoJy9ldGMvd2hhbGVub2RlLWVncmVzcy5uZnQnKQogICAgYXRvbWljKG5mdCx0YWJsZSkKICAgIGlmIG5vdCBleGlzdHM6CiAgICAgICAgcnVuKCduZnQnLCctLWNoZWNrJywnLWYnLHN0cihuZnQpKQogICAgICAgIHN0YXRlWydvd25zX2VncmVzcyddPVRydWU7c2F2ZSgnZWdyZXNzJykKICAgICAgICBydW4oJ25mdCcsJy1mJyxzdHIobmZ0KSkKICAgIGF0b21pYygnL2V0Yy9zeXN0ZW1kL3N5c3RlbS93aGFsZW5vZGUtZWdyZXNzLnNlcnZpY2UnLCdbVW5pdF1cbkJlZm9yZT13aGFsZW5vZGUuc2VydmljZVxuW1NlcnZpY2VdXG5UeXBlPW9uZXNob3RcblJlbWFpbkFmdGVyRXhpdD15ZXNcbkV4ZWNTdGFydD0vdXNyL3NiaW4vbmZ0IC1mIC9ldGMvd2hhbGVub2RlLWVncmVzcy5uZnRcbkV4ZWNTdG9wPS91c3Ivc2Jpbi9uZnQgZGVsZXRlIHRhYmxlIGluZXQgd2hhbGVub2RlX2VncmVzc1xuW0luc3RhbGxdXG5XYW50ZWRCeT1tdWx0aS11c2VyLnRhcmdldFxuJywwbzY0NCkKICAgIHR1bmVfc291cmNlX3BvcnRzKHN0YXRlLHNlbGVjdGVkKQogICAgdHVuZV9rZXJuZWwoZmFjdHMpCiAgICB1bml0PSdbVW5pdF1cbkRlc2NyaXB0aW9uPVdoYWxlTm9kZVxuQWZ0ZXI9bmV0d29yay1vbmxpbmUudGFyZ2V0IHdoYWxlbm9kZS1lZ3Jlc3Muc2VydmljZVxuUmVxdWlyZXM9d2hhbGVub2RlLWVncmVzcy5zZXJ2aWNlXG5XYW50cz1uZXR3b3JrLW9ubGluZS50YXJnZXRcbltTZXJ2aWNlXVxuVXNlcj13aGFsZW5vZGVcbkdyb3VwPXdoYWxlbm9kZVxuV29ya2luZ0RpcmVjdG9yeT0nK3N0cihDT05GKSsnXG5VTWFzaz0wMDc3XG5FbnZpcm9ubWVudD1HT01FTUxJTUlUPScrc3RyKGZhY3RzWydnb19tZW1vcnlfbWliJ10pKydNaUJcbkVudmlyb25tZW50PUdPTUFYUFJPQ1M9JytzdHIoZmFjdHNbJ2NwdXMnXSkrJ1xuRXhlY1N0YXJ0PScrc3RyKGJpbmFyeSkrJyBzZXJ2ZXIgLWMgJytzdHIoQ09ORi8nY29uZmlnLmpzb24nKSsnXG5SZXN0YXJ0PWFsd2F5c1xuUmVzdGFydFNlYz01XG5MaW1pdE5PRklMRT0yNjIxNDRcbk5vTmV3UHJpdmlsZWdlcz10cnVlXG5Qcm90ZWN0SG9tZT10cnVlXG5Qcm90ZWN0U3lzdGVtPXN0cmljdFxuUmVhZFdyaXRlUGF0aHM9JytzdHIoQ09ORikrJ1xuW0luc3RhbGxdXG5XYW50ZWRCeT1tdWx0aS11c2VyLnRhcmdldFxuJwogICAgYXRvbWljKCcvZXRjL3N5c3RlbWQvc3lzdGVtL3doYWxlbm9kZS5zZXJ2aWNlJyx1bml0LDBvNjQ0KQogICAgc3RhdGVbJ293bnNfc2VydmljZSddPVRydWU7c2F2ZSgnY29uZmlndXJlZCcpCiAgICBydW4oJ3N5c3RlbWN0bCcsJ2RhZW1vbi1yZWxvYWQnKQogICAgIyBUYWJsZSBhbHJlYWR5IGxvYWRlZDsgbWFyayBvbmVzaG90IGFjdGl2ZSB3aXRob3V0IGxvYWRpbmcgaXQgYSBzZWNvbmQgdGltZS4KICAgIHJ1bignc3lzdGVtY3RsJywnc3RvcCcsJ3doYWxlbm9kZS1lZ3Jlc3Muc2VydmljZScsY2hlY2s9RmFsc2UpCiAgICBydW4oJ25mdCcsJ2RlbGV0ZScsJ3RhYmxlJywnaW5ldCcsJ3doYWxlbm9kZV9lZ3Jlc3MnLGNoZWNrPUZhbHNlKQogICAgcnVuKCdzeXN0ZW1jdGwnLCdlbmFibGUnLCctLW5vdycsJ3doYWxlbm9kZS1lZ3Jlc3Muc2VydmljZScpCiAgICBzYXZlKCdzdGFydGluZycpCiAgICBydW4oJ3N5c3RlbWN0bCcsJ2VuYWJsZScsJy0tbm93Jywnd2hhbGVub2RlLnNlcnZpY2UnKQogICAgbWlzc2luZz13YWl0X2xpc3RlbmluZyhzZWxlY3RlZCkKICAgIGlmIG1pc3Npbmc6CiAgICAgICAgcnVuKCdzeXN0ZW1jdGwnLCdzdG9wJywnd2hhbGVub2RlLnNlcnZpY2UnLGNoZWNrPUZhbHNlKQogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcign5ZCO56uv55uR5ZCs5pyq5bCx57uq77yM5bey5YGc5q2i5aSx6LSl5pyN5Yqh77yM5Y2P6K6u77yaJysnLCcuam9pbihtaXNzaW5nKSsn77yb5L2/55SoIGpvdXJuYWxjdGwgLXUgd2hhbGVub2RlIOajgOafpeWQjuWPr+WOn+WRveS7pOe7rei3kScpCiAgICB2ZXJpZnlfc2VydmljZShzdGF0ZSkKICAgIHNhdmUoJ2luc3RhbGxlZCcpCiAgICBwcmludCgn5pys5py65a6J6KOF5a6M5oiQ77yaJysnLCAnLmpvaW4ocCsnIOerr+WPoyAnK3N0cihQUk9UT0NPTFNbcF1bMV0pKygnL3VkcCcgaWYgcD09J2h5MicgZWxzZSAnL3RjcCcpIGZvciBwIGluIHNlbGVjdGVkKSsKICAgICAgICAgICfvvIjkupHlronlhajnu4TpnIDmlL7ooYzov5nkupvnq6/lj6PvvInjgIInLGZsdXNoPVRydWUpCiAgICBmaW5pc2goYXJncyxzdGF0ZSxhZG1pbikKCmRlZiBmaW5pc2goYXJncyxzdGF0ZSxhZG1pbj1Ob25lKToKICAgICIiIuWuieijheWQjueahOiHquWKqOatpemqpO+8muebkeaOpyDihpIg6Z2i5p2/5pi+56S6IOKGkiDnrYnmupDnq5nmjqXlhaXosIPluqYv5YiG57uEL+ebkeaOp+OAguavj+atpeWPr+e7rei3keOAgiIiIgogICAgaWYgbm90IHN0YXRlLmdldCgnbW9uaXRvcicpOmluc3RhbGxfbW9uaXRvcihhcmdzLHN0YXRlKQogICAgaWYgbm90IHN0YXRlLmdldCgncHVibGlzaCcsVHJ1ZSk6CiAgICAgICAgcHJpbnQoJ+W3suaMiSAtLW5vLXB1Ymxpc2gg5L+d5oyB6Z2i5p2/6ZqQ6JeP77yb6ZyA6KaB5LiK57q/5pe26L+Q6KGMIC0tc2hvd+OAgicpO3JldHVybgogICAgaWYgbm90IHN0YXRlLmdldCgncHVibGlzaGVkJyk6CiAgICAgICAgYWRtaW49YWRtaW4gb3IgYWRtaW5fdG9rZW4oYXJncykKICAgICAgICBzZXRfc2hvdyhzdGF0ZSxhZG1pbiwxKQogICAgICAgIHNhdmVfc3RhdGUoc3RhdGUsJ3B1Ymxpc2hlZCcpCiAgICAgICAgcHJpbnQoJ+mdouadv+W3suaYvuekuu+8micrJywgJy5qb2luKHArJyMnK3N0cihuKSBmb3IgcCxuIGluIHN0YXRlWydpZHMnXS5pdGVtcygpKSxmbHVzaD1UcnVlKQogICAgYWRtaW49YWRtaW4gb3IgYWRtaW5fdG9rZW4oYXJncykKICAgIHdhaXRfc3luYyhzdGF0ZSxhZG1pbikKICAgIHByaW50KCfnrqHnkIbvvJrlho3mrKHov5DooYzmnKzohJrmnKzlj6/pgInmi6kg6Z2i5p2/6ZqQ6JePIC8g6YeN5paw5pi+56S6IC8g5Y246L2977yb5oiW55u05o6l55SoIC0taGlkZeOAgS0tc2hvd+OAgS0tdW5pbnN0YWxs44CCJykKCmlmIF9fbmFtZV9fPT0nX19tYWluX18nOgogICAgdHJ5OgogICAgICAgIGlmIG5vdCBzeXMuYXJndlsxOl0gb3IgJy0tbWVudScgaW4gc3lzLmFyZ3ZbMTpdOgogICAgICAgICAgICBpbXBvcnQgbm9kZV9tZW51CiAgICAgICAgICAgIG5vZGVfbWVudS5tYWluKFthcmcgZm9yIGFyZyBpbiBzeXMuYXJndlsxOl0gaWYgYXJnIT0nLS1tZW51J10pCiAgICAgICAgZWxpZiBzeXMuYXJndlsxOjJdPT1bJy0taXAtcG9vbCddOgogICAgICAgICAgICBpbXBvcnQgaXBfcG9vbF9jbGkKICAgICAgICAgICAgaXBfcG9vbF9jbGkubWFpbihzeXMuYXJndlsyOl0pCiAgICAgICAgZWxzZTptYWluKCkKICAgIGV4Y2VwdCAoRXhjZXB0aW9uLEtleWJvYXJkSW50ZXJydXB0KSBhcyBlOgogICAgICAgICMgRG8gbm90IGVtaXQgZXhjZXB0aW9uIFVSTHMsIHJlcXVlc3QgYm9kaWVzLCBjcmVkZW50aWFscyBvciBzdGFjayBsb2NhbHMuCiAgICAgICAgcHJpbnQoJ+aTjeS9nOacquWujOaIkO+8micrKHN0cihlKSBpZiBpc2luc3RhbmNlKGUsKFJ1bnRpbWVFcnJvcixWYWx1ZUVycm9yKSkgZWxzZSB0eXBlKGUpLl9fbmFtZV9fKSxmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgc3lzLmV4aXQoMSkK', 'ephemeral_ports.py': 'IiIiTWF4aW1pemUgbm9uLXByaXZpbGVnZWQgc291cmNlIHBvcnRzIHdpdGhvdXQgY29uc3VtaW5nIHNlcnZpY2UvaG9wcGluZyBwb3J0cy4KCk5vIHNlcnZpY2UgcmVzdGFydCwgZGVwZW5kZW5jeSBpbnN0YWxsLCBUQ1AgdGltZW91dCBvciBkdXJhYmlsaXR5IGNoYW5nZXMuClRoZSBzYW1lIGltcGxlbWVudGF0aW9uIGlzIHVzZWQgYnkgbm9kZV9idWlsZCBhbmQgc2NvcGVkIG9ubGluZSBtYWludGVuYW5jZS4KIiIiCmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgaGFzaGxpYgppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IHRlbXBmaWxlCgpMT1csIEhJR0ggPSAxMDI0LCA2NTUzNQpQRVJTSVNUID0gJy9ldGMvc3lzY3RsLmQvenotd2hhbGUtZXBoZW1lcmFsLmNvbmYnClJPTExCQUNLID0gcicnJ2Zyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQganNvbiwgaGFzaGxpYiwgZmNudGwsIG9zLCB0ZW1wZmlsZQpyb290PVBhdGgoX19maWxlX18pLnJlc29sdmUoKS5wYXJlbnQKd2l0aCBvcGVuKCcvcnVuL2xvY2svd2hhbGUtZXBoZW1lcmFsLmxvY2snLCdhJykgYXMgbG9jazoKIGZjbnRsLmZsb2NrKGxvY2ssZmNudGwuTE9DS19FWCkKIG09anNvbi5sb2Fkcygocm9vdC8ncmVjZWlwdC5qc29uJykucmVhZF90ZXh0KCkpCiBiYXNlPVBhdGgoJy9wcm9jL3N5cy9uZXQvaXB2NCcpO3A9UGF0aChtWydwZXJzaXN0ZW50X3BhdGgnXSkKIGFzc2VydCAoYmFzZS8naXBfbG9jYWxfcG9ydF9yYW5nZScpLnJlYWRfdGV4dCgpLnNwbGl0KCk9PW1bJ25ld19yYW5nZSddLnNwbGl0KCksJ1JhbmdlIGNoYW5nZWQ7IHJldmlldyByb2xsYmFjaycKIGFzc2VydCAoYmFzZS8naXBfbG9jYWxfcmVzZXJ2ZWRfcG9ydHMnKS5yZWFkX3RleHQoKS5zdHJpcCgpPT1tWyduZXdfcmVzZXJ2ZWQnXSwnUmVzZXJ2YXRpb25zIGNoYW5nZWQ7IHJldmlldyByb2xsYmFjaycKIGFzc2VydCBoYXNobGliLnNoYTI1NihwLnJlYWRfYnl0ZXMoKSkuaGV4ZGlnZXN0KCk9PW1bJ3BlcnNpc3RlbnRfc2hhMjU2J10sJ1BlcnNpc3RlbnQgZmlsZSBjaGFuZ2VkOyByZXZpZXcgcm9sbGJhY2snCiBvbGQ9cm9vdC8ncGVyc2lzdGVudC5iZWZvcmUnCiBpZiBvbGQuZXhpc3RzKCk6CiAgZmQsbmFtZT10ZW1wZmlsZS5ta3N0ZW1wKHByZWZpeD0nLndoYWxlLXBvcnQtcm9sbGJhY2stJyxkaXI9c3RyKHAucGFyZW50KSkKICB3aXRoIG9zLmZkb3BlbihmZCwnd2InKSBhcyBmOmYud3JpdGUob2xkLnJlYWRfYnl0ZXMoKSk7Zi5mbHVzaCgpO29zLmZzeW5jKGYuZmlsZW5vKCkpCiAgb3MuY2htb2QobmFtZSwwbzY0NCk7b3MucmVwbGFjZShuYW1lLHApCiBlbHNlOnAudW5saW5rKCkKIChiYXNlLydpcF9sb2NhbF9wb3J0X3JhbmdlJykud3JpdGVfdGV4dChtWydvbGRfcmFuZ2UnXSsnXG4nKQogKGJhc2UvJ2lwX2xvY2FsX3Jlc2VydmVkX3BvcnRzJykud3JpdGVfdGV4dChtWydvbGRfcmVzZXJ2ZWQnXSsnXG4nKQogcHJpbnQoJ1Jlc3RvcmVkIG9ubHkgdGhpcyBwb3J0LXBvb2wgY2hhbmdlOyBubyBzZXJ2aWNlcyByZXN0YXJ0ZWQnKQonJycKCgpkZWYgZXhwYW5kKHZhbHVlKToKICAgIHBvcnRzID0gc2V0KCkKICAgIGZvciBwYXJ0IGluIHN0cih2YWx1ZSkuc3BsaXQoJywnKToKICAgICAgICBpZiBub3QgcGFydC5zdHJpcCgpOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGVuZHMgPSBbaW50KG4pIGZvciBuIGluIHBhcnQuc3RyaXAoKS5zcGxpdCgnLScpXQogICAgICAgIGlmIGxlbihlbmRzKSA+IDIgb3Igbm90IDEgPD0gZW5kc1swXSA8PSBlbmRzWy0xXSA8PSBISUdIOgogICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCdJbnZhbGlkIHJlc2VydmVkIHBvcnQgcmFuZ2UnKQogICAgICAgIHBvcnRzLnVwZGF0ZShyYW5nZShlbmRzWzBdLCBlbmRzWy0xXSArIDEpKQogICAgcmV0dXJuIHBvcnRzCgoKZGVmIGNvbXBhY3QocG9ydHMpOgogICAgc3BhbnMgPSBbXQogICAgZm9yIG4gaW4gc29ydGVkKHBvcnRzKToKICAgICAgICBpZiBzcGFucyBhbmQgbiA9PSBzcGFuc1stMV1bMV0gKyAxOgogICAgICAgICAgICBzcGFuc1stMV1bMV0gPSBuCiAgICAgICAgZWxzZToKICAgICAgICAgICAgc3BhbnMuYXBwZW5kKFtuLCBuXSkKICAgIHJldHVybiAnLCcuam9pbihzdHIoYSkgaWYgYSA9PSBiIGVsc2UgJyVkLSVkJyAlIChhLCBiKSBmb3IgYSwgYiBpbiBzcGFucykKCgpkZWYgbGlzdGVuZXJfcG9ydHMob3V0cHV0LCBvbGRfcmFuZ2UpOgogICAgIiIic3MgVURQIFVOQ09OTiBpbmNsdWRlcyBvdXRib3VuZCBzb2NrZXRzOiBuZXZlciByZXNlcnZlIHRoZSBlbnRpcmUgcG9vbC4KCiAgICBUQ1AgTElTVEVOLCBzcGVjaWZpY2FsbHkgYm91bmQgVURQIGFuZCB3aWxkY2FyZCBVRFAgb3V0c2lkZSB0aGUgb2xkIGVwaGVtZXJhbAogICAgcmFuZ2UgYXJlIHNlcnZpY2UgY2FuZGlkYXRlcy4gSW4tcmFuZ2Ugd2lsZGNhcmQgc2VydmljZXMgbXVzdCBiZSBwcm92aWRlZCBieQogICAgdGhlIGRlcGxveW1lbnQgcGxhbiAob3IgZXhpc3RpbmcgcmVzZXJ2YXRpb25zKSwgZS5nLiBIWTIgb24gcG9ydCAyNDQ0My4KICAgICIiIgogICAgcG9ydHMgPSBzZXQoKQogICAgZm9yIGxpbmUgaW4gb3V0cHV0LnNwbGl0bGluZXMoKToKICAgICAgICBmaWVsZHMgPSBsaW5lLnNwbGl0KCkKICAgICAgICBpZiBsZW4oZmllbGRzKSA8IDUgb3IgZmllbGRzWzBdIG5vdCBpbiAoJ3RjcCcsICd1ZHAnKToKICAgICAgICAgICAgY29udGludWUKICAgICAgICBhZGRyZXNzLCBwb3J0ID0gZmllbGRzWzRdLnJzcGxpdCgnOicsIDEpCiAgICAgICAgaWYgcG9ydC5pc2RpZ2l0KCkgYW5kIChmaWVsZHNbMF0gPT0gJ3RjcCcgb3IKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYWRkcmVzcyBub3QgaW4gKCcqJywgJzAuMC4wLjAnLCAnWzo6XScsICc6OicpIG9yCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIG5vdCBvbGRfcmFuZ2VbMF0gPD0gaW50KHBvcnQpIDw9IG9sZF9yYW5nZVsxXSk6CiAgICAgICAgICAgIHBvcnRzLmFkZChpbnQocG9ydCkpCiAgICByZXR1cm4gcG9ydHMKCgpkZWYgYXRvbWljX3dyaXRlKHBhdGgsIHJhdyk6CiAgICBwYXRoID0gUGF0aChwYXRoKQogICAgZmQsIG5hbWUgPSB0ZW1wZmlsZS5ta3N0ZW1wKHByZWZpeD0nLicgKyBwYXRoLm5hbWUsIGRpcj1zdHIocGF0aC5wYXJlbnQpKQogICAgdHJ5OgogICAgICAgIHdpdGggb3MuZmRvcGVuKGZkLCAnd2InKSBhcyBoYW5kbGU6CiAgICAgICAgICAgIGhhbmRsZS53cml0ZShyYXcpCiAgICAgICAgICAgIGhhbmRsZS5mbHVzaCgpCiAgICAgICAgICAgIG9zLmZzeW5jKGhhbmRsZS5maWxlbm8oKSkKICAgICAgICBvcy5jaG1vZChuYW1lLCAwbzY0NCkKICAgICAgICBvcy5yZXBsYWNlKG5hbWUsIHBhdGgpCiAgICBmaW5hbGx5OgogICAgICAgIGlmIG9zLnBhdGguZXhpc3RzKG5hbWUpOgogICAgICAgICAgICBvcy51bmxpbmsobmFtZSkKCgpkZWYgY29uZmlndXJlKGV4dHJhX3Jlc2VydmVkPScnLCBhcHBseT1GYWxzZSk6CiAgICBpbXBvcnQgZmNudGwgICMgUmVtb3RlIExpbnV4IG9ubHk7IHNvdXJjZSBnZW5lcmF0aW9uIGFsc28gcnVucyBvbiBXaW5kb3dzLgogICAgaWYgb3MuZ2V0ZXVpZCgpICE9IDA6CiAgICAgICAgcmFpc2UgUGVybWlzc2lvbkVycm9yKCdSZXF1aXJlcyBleGlzdGluZyByb290IG9yIG5vbmludGVyYWN0aXZlIHN1ZG8nKQogICAgd2l0aCBvcGVuKCcvcnVuL2xvY2svd2hhbGUtZXBoZW1lcmFsLmxvY2snLCAnYScpIGFzIGxvY2s6CiAgICAgICAgZmNudGwuZmxvY2sobG9jaywgZmNudGwuTE9DS19FWCkKICAgICAgICBiYXNlID0gUGF0aCgnL3Byb2Mvc3lzL25ldC9pcHY0JykKICAgICAgICByYW5nZV9wYXRoID0gYmFzZSAvICdpcF9sb2NhbF9wb3J0X3JhbmdlJwogICAgICAgIHJlc2VydmVkX3BhdGggPSBiYXNlIC8gJ2lwX2xvY2FsX3Jlc2VydmVkX3BvcnRzJwogICAgICAgIG9sZF9yYW5nZSA9IHJhbmdlX3BhdGgucmVhZF90ZXh0KCkuc3RyaXAoKQogICAgICAgIG9sZF9yZXNlcnZlZCA9IHJlc2VydmVkX3BhdGgucmVhZF90ZXh0KCkuc3RyaXAoKQogICAgICAgIGxvdywgaGlnaCA9IG1hcChpbnQsIG9sZF9yYW5nZS5zcGxpdCgpKQogICAgICAgIGJvdW5kYXJ5ID0gYmFzZSAvICdpcF91bnByaXZpbGVnZWRfcG9ydF9zdGFydCcKICAgICAgICAjIE9sZGVyIExpbnV4IGtlcm5lbHMgcHJlZGF0ZSB0aGlzIHNldHRpbmcgYW5kIHVzZSB0aGUgZml4ZWQgMTAyNCBib3VuZGFyeS4KICAgICAgICBwcml2aWxlZ2VkID0gaW50KGJvdW5kYXJ5LnJlYWRfdGV4dCgpKSBpZiBib3VuZGFyeS5leGlzdHMoKSBlbHNlIDEwMjQKICAgICAgICBpZiBwcml2aWxlZ2VkID4gTE9XOgogICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCdOb25zdGFuZGFyZCBwcml2aWxlZ2VkLXBvcnQgYm91bmRhcnk7IHJldmlldyBiZWZvcmUgZXhwYW5kaW5nJykKICAgICAgICBsaXN0ZW5lcnMgPSBzdWJwcm9jZXNzLmNoZWNrX291dHB1dChbJ3NzJywgJy1IJywgJy1sbnR1J10sIHRleHQ9VHJ1ZSwgdGltZW91dD0yMCkKICAgICAgICByZXNlcnZlZCA9IGV4cGFuZChvbGRfcmVzZXJ2ZWQpIHwgZXhwYW5kKGV4dHJhX3Jlc2VydmVkKSB8IGxpc3RlbmVyX3BvcnRzKGxpc3RlbmVycywgKGxvdywgaGlnaCkpCiAgICAgICAgbmV3X3Jlc2VydmVkID0gY29tcGFjdChyZXNlcnZlZCkKICAgICAgICBjYXBhY2l0eSA9IEhJR0ggLSBMT1cgKyAxIC0gc3VtKExPVyA8PSBuIDw9IEhJR0ggZm9yIG4gaW4gcmVzZXJ2ZWQpCiAgICAgICAgaWYgY2FwYWNpdHkgPCAxNjM4NDoKICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJvcignUmVzZXJ2ZWQgcG9ydHMgbGVhdmUgaW5zdWZmaWNpZW50IGNhcGFjaXR5OyByZXZpZXcgcGxhbicpCiAgICAgICAgYm9keSA9ICgnIyBNYW5hZ2VkIGJ5IFdoYWxlIGVwaGVtZXJhbF9wb3J0cy5weTsgcHJlc2VydmUgc2VydmljZSBhbmQgaG9wcGluZyByZXNlcnZhdGlvbnMuXG4nCiAgICAgICAgICAgICAgICAnbmV0LmlwdjQuaXBfbG9jYWxfcmVzZXJ2ZWRfcG9ydHMgPSAnICsgbmV3X3Jlc2VydmVkICsgJ1xuJwogICAgICAgICAgICAgICAgJ25ldC5pcHY0LmlwX2xvY2FsX3BvcnRfcmFuZ2UgPSAlZCAlZFxuJyAlIChMT1csIEhJR0gpKS5lbmNvZGUoKQogICAgICAgIHBhdGggPSBQYXRoKFBFUlNJU1QpCiAgICAgICAgcHJldmlvdXMgPSBwYXRoLnJlYWRfYnl0ZXMoKSBpZiBwYXRoLmV4aXN0cygpIGVsc2UgTm9uZQogICAgICAgIHJlc3VsdCA9IHsnb2xkX3JhbmdlJzogb2xkX3JhbmdlLCAnbmV3X3JhbmdlJzogJyVkICVkJyAlIChMT1csIEhJR0gpLAogICAgICAgICAgICAgICAgICAnb2xkX3Jlc2VydmVkJzogb2xkX3Jlc2VydmVkLCAnbmV3X3Jlc2VydmVkJzogbmV3X3Jlc2VydmVkLAogICAgICAgICAgICAgICAgICAnY2FwYWNpdHknOiBjYXBhY2l0eSwgJ2FwcGxpZWQnOiBGYWxzZSwgJ3BlcnNpc3RlbnRfcGF0aCc6IFBFUlNJU1QsCiAgICAgICAgICAgICAgICAgICdwZXJzaXN0ZW50X3NoYTI1Nic6IGhhc2hsaWIuc2hhMjU2KGJvZHkpLmhleGRpZ2VzdCgpfQogICAgICAgIGlmIG5vdCBhcHBseToKICAgICAgICAgICAgcmV0dXJuIHJlc3VsdAogICAgICAgIGJhY2t1cCA9IFBhdGgodGVtcGZpbGUubWtkdGVtcChwcmVmaXg9J3doYWxlLWVwaGVtZXJhbC1tYXgtJywgZGlyPScvcm9vdCcpKQogICAgICAgIG9zLmNobW9kKGJhY2t1cCwgMG83MDApCiAgICAgICAgaWYgcHJldmlvdXMgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIChiYWNrdXAgLyAncGVyc2lzdGVudC5iZWZvcmUnKS53cml0ZV9ieXRlcyhwcmV2aW91cykKICAgICAgICByZXN1bHRbJ2JhY2t1cCddID0gc3RyKGJhY2t1cCkKICAgICAgICAoYmFja3VwIC8gJ2JlZm9yZS5qc29uJykud3JpdGVfdGV4dChqc29uLmR1bXBzKHJlc3VsdCwgaW5kZW50PTIpKQogICAgICAgIHRyeToKICAgICAgICAgICAgIyBSZXNlcnZlIGJlZm9yZSBleHBhbnNpb24gc28gc2VydmljZXMgbmV2ZXIgZW50ZXIgYXV0b21hdGljIGFsbG9jYXRpb24uCiAgICAgICAgICAgIHJlc2VydmVkX3BhdGgud3JpdGVfdGV4dChuZXdfcmVzZXJ2ZWQgKyAnXG4nKQogICAgICAgICAgICByYW5nZV9wYXRoLndyaXRlX3RleHQocmVzdWx0WyduZXdfcmFuZ2UnXSArICdcbicpCiAgICAgICAgICAgIGF0b21pY193cml0ZShwYXRoLCBib2R5KQogICAgICAgICAgICBhc3NlcnQgcmFuZ2VfcGF0aC5yZWFkX3RleHQoKS5zcGxpdCgpID09IFtzdHIoTE9XKSwgc3RyKEhJR0gpXQogICAgICAgICAgICBhc3NlcnQgZXhwYW5kKHJlc2VydmVkX3BhdGgucmVhZF90ZXh0KCkpID09IHJlc2VydmVkCiAgICAgICAgICAgIGFzc2VydCBwYXRoLnJlYWRfYnl0ZXMoKSA9PSBib2R5CiAgICAgICAgICAgIHJlc3VsdFsnYXBwbGllZCddID0gVHJ1ZQogICAgICAgICAgICAoYmFja3VwIC8gJ3JlY2VpcHQuanNvbicpLndyaXRlX3RleHQoanNvbi5kdW1wcyhyZXN1bHQsIGluZGVudD0yKSkKICAgICAgICAgICAgKGJhY2t1cCAvICdyb2xsYmFjay5weScpLndyaXRlX3RleHQoUk9MTEJBQ0spCiAgICAgICAgICAgIChiYWNrdXAgLyAncm9sbGJhY2sucHknKS5jaG1vZCgwbzcwMCkKICAgICAgICAgICAgcmV0dXJuIHJlc3VsdAogICAgICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgICAgICMgUmVzdG9yZSBvbmx5IG91ciBleGFjdCB3cml0ZXM7IG5ldmVyIG92ZXJ3cml0ZSBjb25jdXJyZW50IGV4dGVybmFsIGVkaXRzLgogICAgICAgICAgICBpZiByYW5nZV9wYXRoLnJlYWRfdGV4dCgpLnNwbGl0KCkgPT0gW3N0cihMT1cpLCBzdHIoSElHSCldOgogICAgICAgICAgICAgICAgcmFuZ2VfcGF0aC53cml0ZV90ZXh0KG9sZF9yYW5nZSArICdcbicpCiAgICAgICAgICAgIGlmIHJlc2VydmVkX3BhdGgucmVhZF90ZXh0KCkuc3RyaXAoKSA9PSBuZXdfcmVzZXJ2ZWQ6CiAgICAgICAgICAgICAgICByZXNlcnZlZF9wYXRoLndyaXRlX3RleHQob2xkX3Jlc2VydmVkICsgJ1xuJykKICAgICAgICAgICAgaWYgcGF0aC5leGlzdHMoKSBhbmQgcGF0aC5yZWFkX2J5dGVzKCkgPT0gYm9keToKICAgICAgICAgICAgICAgIGlmIHByZXZpb3VzIGlzIE5vbmU6CiAgICAgICAgICAgICAgICAgICAgcGF0aC51bmxpbmsoKQogICAgICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAgICAgICBhdG9taWNfd3JpdGUocGF0aCwgcHJldmlvdXMpCiAgICAgICAgICAgIHJhaXNlCgoKZGVmIHJlbW90ZV9zY3JpcHQoZXh0cmFfcmVzZXJ2ZWQ9JycsIGFwcGx5PVRydWUpOgogICAgIyBObyBjcmVkZW50aWFscyBvciB0YXJnZXQgZGF0YSBhcmUgZW1iZWRkZWQgYmV5b25kIGV4cGxpY2l0IHJlc2VydmVkIHBvcnRzLgogICAgcmV0dXJuIChQYXRoKF9fZmlsZV9fKS5yZWFkX3RleHQoZW5jb2Rpbmc9J3V0Zi04JykgKwogICAgICAgICAgICAnXG5wcmludChqc29uLmR1bXBzKGNvbmZpZ3VyZSglciwgYXBwbHk9JXIpKSlcbicgJSAoZXh0cmFfcmVzZXJ2ZWQsIGFwcGx5KSkK', 'ip_pool.py': 'IiIiUHVibGljIElQdjQgZGlzY292ZXJ5IGFuZCBkdXJhYmxlIGludGVudCBwbGFubmluZzsgbm8gcGFuZWwgbXV0YXRpb25zIGhlcmUuIiIiCmltcG9ydCBjb3B5CmltcG9ydCBpcGFkZHJlc3MKaW1wb3J0IGpzb24KaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IHRpbWUKaW1wb3J0IHV1aWQKCiMgRGVsaWJlcmF0ZWx5IHN0YWJsZSBhY3Jvc3MgUHl0aG9uIHZlcnNpb25zLiBDb25zZXJ2YXRpdmVseSBleGNsdWRlIHNwZWNpYWwtdXNlCiMgc3BhY2UsIGluY2x1ZGluZyBwcm90b2NvbCBhc3NpZ25tZW50cyBhbmQgZGVwcmVjYXRlZCB0cmFuc2l0aW9uIG1lY2hhbmlzbXMuCkVYQ0xVREVEID0gdHVwbGUoaXBhZGRyZXNzLmlwX25ldHdvcmsoeCkgZm9yIHggaW4gKAogICAgJzAuMC4wLjAvOCcsICcxMC4wLjAuMC84JywgJzEwMC42NC4wLjAvMTAnLCAnMTI3LjAuMC4wLzgnLAogICAgJzE2OS4yNTQuMC4wLzE2JywgJzE3Mi4xNi4wLjAvMTInLCAnMTkyLjAuMC4wLzI0JywgJzE5Mi4wLjIuMC8yNCcsCiAgICAnMTkyLjg4Ljk5LjAvMjQnLCAnMTkyLjE2OC4wLjAvMTYnLCAnMTk4LjE4LjAuMC8xNScsCiAgICAnMTk4LjUxLjEwMC4wLzI0JywgJzIwMy4wLjExMy4wLzI0JywgJzIyNC4wLjAuMC80JywgJzI0MC4wLjAuMC80JykpCkVDSE9fVVJMUyA9ICgnaHR0cHM6Ly9hcGkuaXBpZnkub3JnJywgJ2h0dHBzOi8vY2hlY2tpcC5hbWF6b25hd3MuY29tJykKVklSVFVBTF9LSU5EUyA9IHsnYnJpZGdlJywgJ3ZldGgnLCAndHVuJywgJ3RhcCcsICd3aXJlZ3VhcmQnLCAndnhsYW4nLCAnZ3JlJywgJ2dyZXRhcCcsICdkdW1teSd9CgoKZGVmIHB1YmxpY19pcHY0KHZhbHVlKToKICAgIHRyeToKICAgICAgICBhZGRyZXNzID0gaXBhZGRyZXNzLklQdjRBZGRyZXNzKHZhbHVlKQogICAgZXhjZXB0IChWYWx1ZUVycm9yLCBUeXBlRXJyb3IpOgogICAgICAgIHJldHVybiBGYWxzZQogICAgcmV0dXJuIG5vdCBhbnkoYWRkcmVzcyBpbiBuZXR3b3JrIGZvciBuZXR3b3JrIGluIEVYQ0xVREVEKQoKCmRlZiBhZGRyZXNzZXMoZG9jdW1lbnQsIGludGVyZmFjZXM9Tm9uZSk6CiAgICBpZiBub3QgaXNpbnN0YW5jZShkb2N1bWVudCwgbGlzdCk6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcign572R5Y2h5omr5o+P57uT5p6c5qC85byP6ZSZ6K+v77yM5LiN5omn6KGM57y65aSx5Yik5patJykKICAgIHJlc3VsdCA9IHt9CiAgICBmb3IgbGluayBpbiBkb2N1bWVudDoKICAgICAgICBuYW1lID0gbGlua1snaWZuYW1lJ10KICAgICAgICBpZiBpbnRlcmZhY2VzIGlzIG5vdCBOb25lIGFuZCBuYW1lIG5vdCBpbiBpbnRlcmZhY2VzOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGtpbmQgPSBsaW5rLmdldCgnbGlua2luZm8nLCB7fSkuZ2V0KCdpbmZvX2tpbmQnKQogICAgICAgIGlmIGtpbmQgaW4gVklSVFVBTF9LSU5EUyBvciBsaW5rLmdldCgnbGlua190eXBlJykgPT0gJ2xvb3BiYWNrJzoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBpZiAnVVAnIG5vdCBpbiBsaW5rLmdldCgnZmxhZ3MnLCBbXSk6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgZm9yIGl0ZW0gaW4gbGluay5nZXQoJ2FkZHJfaW5mbycsIFtdKToKICAgICAgICAgICAgaXAgPSBpdGVtLmdldCgnbG9jYWwnKQogICAgICAgICAgICBpZiBpdGVtLmdldCgnZmFtaWx5JykgIT0gJ2luZXQnIG9yIGl0ZW0uZ2V0KCdzY29wZScpICE9ICdnbG9iYWwnIG9yIG5vdCBwdWJsaWNfaXB2NChpcCk6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBmbGFncyA9IHNldChpdGVtLmdldCgnZmxhZ3MnLCBbXSkpCiAgICAgICAgICAgIGlmIGZsYWdzICYgeyd0ZW50YXRpdmUnLCAnZGFkZmFpbGVkJywgJ2RlcHJlY2F0ZWQnfSBvciBhbnkoaXRlbS5nZXQoaykgZm9yIGsgaW4gKCd0ZW50YXRpdmUnLCAnZGFkZmFpbGVkJywgJ2RlcHJlY2F0ZWQnKSk6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBpZiBpdGVtLmdldCgndmFsaWRfbGlmZV90aW1lJykgPT0gMCBvciBpdGVtLmdldCgncHJlZmVycmVkX2xpZmVfdGltZScpID09IDA6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBpZiBpcCBpbiByZXN1bHQgYW5kIHJlc3VsdFtpcF0gIT0gbmFtZToKICAgICAgICAgICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoJ+WFrOe9keWcsOWdgOWHuueOsOWcqOWkmuS4que9keWNoe+8jOmcgOWFiOa2iOmZpOatp+S5iScpCiAgICAgICAgICAgIHJlc3VsdFtpcF0gPSBuYW1lCiAgICByZXR1cm4gcmVzdWx0CgoKZGVmIHNjYW4oaW50ZXJmYWNlcz1Ob25lKToKICAgIHByb2MgPSBzdWJwcm9jZXNzLnJ1bihbJ2lwJywgJy1qJywgJy1kJywgJy00JywgJ2FkZHInLCAnc2hvdyddLCBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUsIHRpbWVvdXQ9MTUpCiAgICBpZiBwcm9jLnJldHVybmNvZGU6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCfnvZHljaHmiavmj4/lpLHotKXvvIzkv53nlZnljp/nirbmgIEnKQogICAgcmV0dXJuIGFkZHJlc3Nlcyhqc29uLmxvYWRzKHByb2Muc3Rkb3V0KSwgaW50ZXJmYWNlcykKCgpkZWYgdmVyaWZ5X2VncmVzcyhpcCk6CiAgICBpZiBub3QgcHVibGljX2lwdjQoaXApOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoJ+S7heWFgeiuuOWFrOe9kSBJUHY0JykKICAgIG9ic2VydmF0aW9ucyA9IFtdCiAgICBmb3IgdXJsIGluIEVDSE9fVVJMUzoKICAgICAgICAjIERpc2FibGUgaW5oZXJpdGVkIHByb3h5IHNldHRpbmdzIGFuZCBjdXJscmM7IGJpbmQgZWFjaCBzb3VyY2UgZXhwbGljaXRseS4KICAgICAgICBwcm9jID0gc3VicHJvY2Vzcy5ydW4oWydjdXJsJywgJy1xJywgJy00JywgJy0tc2lsZW50JywgJy0tc2hvdy1lcnJvcicsICctLWZhaWwnLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgJy0tbm9wcm94eScsICcqJywgJy0tcHJvdG8nLCAnPWh0dHBzJywgJy0tbWF4LXRpbWUnLCAnOCcsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAnLS1tYXgtZmlsZXNpemUnLCAnMTI4JywgJy0taW50ZXJmYWNlJywgaXAsIHVybF0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSwgdGltZW91dD0xMikKICAgICAgICB2YWx1ZSA9IHByb2Muc3Rkb3V0LnN0cmlwKCkKICAgICAgICBvYnNlcnZhdGlvbnMuYXBwZW5kKHZhbHVlIGlmIHByb2MucmV0dXJuY29kZSA9PSAwIGFuZCBwdWJsaWNfaXB2NCh2YWx1ZSkgZWxzZSBOb25lKQogICAgaWYgYWxsKHZhbHVlID09IGlwIGZvciB2YWx1ZSBpbiBvYnNlcnZhdGlvbnMpOgogICAgICAgIHN0YXR1cyA9ICd2ZXJpZmllZCcKICAgIGVsaWYgYW55KHZhbHVlIGlzIG5vdCBOb25lIGFuZCB2YWx1ZSAhPSBpcCBmb3IgdmFsdWUgaW4gb2JzZXJ2YXRpb25zKToKICAgICAgICBzdGF0dXMgPSAnbWlzbWF0Y2gnCiAgICBlbHNlOgogICAgICAgIHN0YXR1cyA9ICd1bmtub3duJwogICAgcmV0dXJuIHsnc3RhdHVzJzogc3RhdHVzLCAnb2JzZXJ2YXRpb25zJzogb2JzZXJ2YXRpb25zfQoKCmRlZiBuZXdfcG9vbChzZXJ2ZXJfaWQ9Tm9uZSk6CiAgICByZXR1cm4geydzY2hlbWEnOiAxLCAnc2VydmVyX2lkJzogc2VydmVyX2lkIG9yIHV1aWQudXVpZDQoKS5oZXgsCiAgICAgICAgICAgICdwYXVzZWQnOiBGYWxzZSwgJ2F1dG9fZXhwYW5kJzogRmFsc2UsICdhdXRvX3JlcGxhY2UnOiBUcnVlLAogICAgICAgICAgICAnYWRkcmVzc2VzJzoge30sICdpbnRlbnRzJzogW10sICdoaXN0b3J5JzogW10sICdsYXN0X3NjYW4nOiBOb25lfQoKCmRlZiBldmVudChwb29sLCBhY3Rpb24sIG5vdywgKipmaWVsZHMpOgogICAgcG9vbFsnaGlzdG9yeSddLmFwcGVuZChkaWN0KGF0PW5vdywgYWN0aW9uPWFjdGlvbiwgKipmaWVsZHMpKQogICAgcG9vbFsnaGlzdG9yeSddID0gcG9vbFsnaGlzdG9yeSddWy0yMDA6XQoKCmRlZiByZWNvbmNpbGUob3JpZ2luYWwsIGZvdW5kLCByZXN1bHRzLCBub3c9Tm9uZSwgYm9vdF9pZD1Ob25lLCB1cHRpbWU9MzYwMCk6CiAgICAiIiJSZXR1cm4gbmV3IHN0YXRlLiBNaXNzaW5nIGNvdW50cyBhZHZhbmNlIG9ubHkgb24gc3BhY2VkLCBzdWNjZXNzZnVsIHNjYW5zLgoKICAgIFRoaXMgcGxhbnMgZHVyYWJsZSBpbnRlbnQ7IGl0IG5ldmVyIGNsYWltcyBpbnRlbnQgaGFzIGJlZW4gYXBwbGllZCByZW1vdGVseS4KICAgIEEgc2VwYXJhdGUgZXhlY3V0b3IgbXVzdCByZXZhbGlkYXRlIGFuZCBhY2tub3dsZWRnZSBlYWNoIGFjdGlvbi4KICAgICIiIgogICAgbm93ID0gdGltZS50aW1lKCkgaWYgbm93IGlzIE5vbmUgZWxzZSBub3cKICAgIGlmIG5vdCBpc2luc3RhbmNlKGZvdW5kLCBkaWN0KSBvciBhbnkobm90IHB1YmxpY19pcHY0KGlwKSBmb3IgaXAgaW4gZm91bmQpOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoJ+aXoOaViOWcsOWdgOaJq+aPjycpCiAgICBwb29sID0gY29weS5kZWVwY29weShvcmlnaW5hbCkKICAgIGlmIHBvb2wuZ2V0KCdzY2hlbWEnKSAhPSAxOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoJ+S4jeaUr+aMgeeahOWcsOWdgOaxoOeJiOacrCcpCiAgICBwcmV2aW91cyA9IHBvb2wuZ2V0KCdsYXN0X3NjYW4nKQogICAgc3BhY2VkID0gcHJldmlvdXMgaXMgTm9uZSBvciBub3cgLSBwcmV2aW91cyA+PSAyNDAKICAgIG5ld19ib290ID0gcG9vbC5nZXQoJ2Jvb3RfaWQnKSAhPSBib290X2lkCiAgICBpZiBuZXdfYm9vdDoKICAgICAgICBmb3IgZW50cnkgaW4gcG9vbFsnYWRkcmVzc2VzJ10udmFsdWVzKCk6CiAgICAgICAgICAgIGVudHJ5WydtaXNzaW5nX2NvdW50J10gPSAwCiAgICBmb3IgaXAsIGludGVyZmFjZSBpbiBmb3VuZC5pdGVtcygpOgogICAgICAgIGVudHJ5ID0gcG9vbFsnYWRkcmVzc2VzJ10uc2V0ZGVmYXVsdChpcCwgeydtb2RlJzogJ3N0YW5kYnknLCAnbG9ja2VkJzogRmFsc2UsICdtaXNzaW5nX2NvdW50JzogMH0pCiAgICAgICAgZW50cnkudXBkYXRlKGludGVyZmFjZT1pbnRlcmZhY2UsIHByZXNlbnQ9VHJ1ZSwgbWlzc2luZ19jb3VudD0wLCBzZWVuX2F0PW5vdykKICAgICAgICByZXN1bHQgPSByZXN1bHRzLmdldChpcCwgeydzdGF0dXMnOiAndW5rbm93bid9KQogICAgICAgIGlmIHJlc3VsdC5nZXQoJ3N0YXR1cycpIG5vdCBpbiAoJ3Vua25vd24nLCdtaXNtYXRjaCcsJ3ZlcmlmaWVkJyk6CiAgICAgICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoJ+aXoOaViOWHuuWPo+mqjOivgee7k+aenCcpCiAgICAgICAgZW50cnlbJ2VncmVzcyddID0gcmVzdWx0WydzdGF0dXMnXQogICAgICAgIGVudHJ5WydjaGVja2VkX2F0J10gPSBub3cKICAgIGZvciBpcCwgZW50cnkgaW4gcG9vbFsnYWRkcmVzc2VzJ10uaXRlbXMoKToKICAgICAgICBpZiBpcCBub3QgaW4gZm91bmQ6CiAgICAgICAgICAgIGVudHJ5WydwcmVzZW50J10gPSBGYWxzZQogICAgICAgICAgICBlbnRyeVsnZWdyZXNzJ10gPSAndW5rbm93bicKICAgICAgICAgICAgaWYgc3BhY2VkIGFuZCBub3QgbmV3X2Jvb3QgYW5kIHVwdGltZSA+PSAxODA6CiAgICAgICAgICAgICAgICBlbnRyeVsnbWlzc2luZ19jb3VudCddID0gZW50cnkuZ2V0KCdtaXNzaW5nX2NvdW50JywgMCkgKyAxCiAgICBwb29sLnVwZGF0ZShsYXN0X3NjYW49bWF4KG5vdywgcHJldmlvdXMgb3Igbm93KSwgYm9vdF9pZD1ib290X2lkKQogICAgaWYgbm90IHBvb2xbJ3BhdXNlZCddOgogICAgICAgIHBlbmRpbmdfaXBzID0ge2lwIGZvciBpbnRlbnQgaW4gcG9vbFsnaW50ZW50cyddIGlmIGludGVudFsnc3RhdHVzJ10gaW4gKCdwZW5kaW5nJywnY2xlYW51cF9yZXF1aXJlZCcpCiAgICAgICAgICAgICAgICAgICAgICAgZm9yIGlwIGluIChpbnRlbnQuZ2V0KCdvbGQnKSwgaW50ZW50LmdldCgnbmV3JykpIGlmIGlwfQogICAgICAgIGZvciBpcCwgZW50cnkgaW4gc29ydGVkKHBvb2xbJ2FkZHJlc3NlcyddLml0ZW1zKCkpOgogICAgICAgICAgICBpZiBlbnRyeS5nZXQoJ2xvY2tlZCcpIG9yIGlwIGluIHBlbmRpbmdfaXBzIG9yIG5vdyA8IGVudHJ5LmdldCgnY29vbGRvd25fdW50aWwnLCAwKToKICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgICAgIGlmIGVudHJ5Wydtb2RlJ10gPT0gJ2FjdGl2ZScgYW5kIGVudHJ5LmdldCgnbWlzc2luZ19jb3VudCcsIDApID49IDI6CiAgICAgICAgICAgICAgICBjYW5kaWRhdGVzID0gW3AgZm9yIHAsIGUgaW4gc29ydGVkKHBvb2xbJ2FkZHJlc3NlcyddLml0ZW1zKCkpCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlmIHAgbm90IGluIHBlbmRpbmdfaXBzIGFuZCBlbGlnaWJsZShlLCBub3cpXQogICAgICAgICAgICAgICAgdGFyZ2V0ID0gY2FuZGlkYXRlc1swXSBpZiBjYW5kaWRhdGVzIGFuZCBwb29sWydhdXRvX3JlcGxhY2UnXSBlbHNlIE5vbmUKICAgICAgICAgICAgICAgIGludGVudCA9IGVucXVldWUocG9vbCwgJ3JlcGxhY2UnIGlmIHRhcmdldCBlbHNlICdoaWRlJywgaXAsIHRhcmdldCwgbm93LCAnYXV0b21hdGljJykKICAgICAgICAgICAgICAgIHBlbmRpbmdfaXBzLnVwZGF0ZSh4IGZvciB4IGluIChpbnRlbnRbJ29sZCddLCBpbnRlbnRbJ25ldyddKSBpZiB4KQogICAgICAgICAgICBlbGlmIHBvb2xbJ2F1dG9fZXhwYW5kJ10gYW5kIGVsaWdpYmxlKGVudHJ5LCBub3cpOgogICAgICAgICAgICAgICAgZW5xdWV1ZShwb29sLCAnZW5hYmxlJywgTm9uZSwgaXAsIG5vdywgJ2F1dG9tYXRpYycpCiAgICAgICAgICAgICAgICBwZW5kaW5nX2lwcy5hZGQoaXApCiAgICByZXR1cm4gcG9vbAoKCmRlZiBlbGlnaWJsZShlbnRyeSwgbm93KToKICAgIHJldHVybiAoZW50cnlbJ21vZGUnXSA9PSAnc3RhbmRieScgYW5kIG5vdCBlbnRyeS5nZXQoJ2xvY2tlZCcpIGFuZCBlbnRyeS5nZXQoJ3ByZXNlbnQnKQogICAgICAgICAgICBhbmQgZW50cnkuZ2V0KCdlZ3Jlc3MnKSA9PSAndmVyaWZpZWQnIGFuZCAwIDw9IG5vdy1lbnRyeS5nZXQoJ2NoZWNrZWRfYXQnLCAwKSA8PSAzMDAKICAgICAgICAgICAgYW5kIG5vdyA+PSBlbnRyeS5nZXQoJ2Nvb2xkb3duX3VudGlsJywgMCkpCgoKZGVmIGVucXVldWUocG9vbCwgYWN0aW9uLCBvbGQsIG5ldywgbm93LCBhY3Rvcik6CiAgICB1bmZpbmlzaGVkPXsncGVuZGluZycsJ2NsZWFudXBfcmVxdWlyZWQnfQogICAgaWYgbGVuKFt4IGZvciB4IGluIHBvb2xbJ2ludGVudHMnXSBpZiB4WydzdGF0dXMnXSBpbiB1bmZpbmlzaGVkXSkgPj0gNjQ6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCflvoXlpITnkIbmk43kvZzov4flpJrvvIzor7flhYjlpITnkIblt7LmnInorqHliJInKQogICAgcG9vbFsnaW50ZW50cyddPVt4IGZvciB4IGluIHBvb2xbJ2ludGVudHMnXSBpZiB4WydzdGF0dXMnXSBpbiB1bmZpbmlzaGVkXStbCiAgICAgICAgeCBmb3IgeCBpbiBwb29sWydpbnRlbnRzJ10gaWYgeFsnc3RhdHVzJ10gbm90IGluIHVuZmluaXNoZWRdWy0xMDA6XQogICAgaW50ZW50ID0geydpZCc6IHV1aWQudXVpZDQoKS5oZXgsICdhY3Rpb24nOiBhY3Rpb24sICdvbGQnOiBvbGQsICduZXcnOiBuZXcsCiAgICAgICAgICAgICAgJ2F0Jzogbm93LCAnYWN0b3InOiBhY3RvciwgJ3N0YXR1cyc6ICdwZW5kaW5nJ30KICAgIHBvb2xbJ2ludGVudHMnXS5hcHBlbmQoaW50ZW50KQogICAgZXZlbnQocG9vbCwgJ3BsYW5uZWQnLCBub3csIGludGVudF9pZD1pbnRlbnRbJ2lkJ10sIG9wZXJhdGlvbj1hY3Rpb24sIG9sZD1vbGQsIG5ldz1uZXcpCiAgICByZXR1cm4gaW50ZW50CgoKZGVmIGNhbmNlbChpbnRlbnQpOgogICAgIyBBIHByZXBhcmVkIHRyYW5zYWN0aW9uIG1heSBvd24gaGlkZGVuIHJvd3Mgb3IgYSBydW5uaW5nIGNhbmRpZGF0ZSBzZXJ2aWNlLgogICAgIyBQcmVzZXJ2ZSBpdHMgam91cm5hbCBmb3IgZXhwbGljaXQgY2xlYW51cCByYXRoZXIgdGhhbiBzaWxlbnRseSBsb3NpbmcgaXQuCiAgICBpbnRlbnRbJ3N0YXR1cyddPSdjbGVhbnVwX3JlcXVpcmVkJyBpZiBpbnRlbnQuZ2V0KCdjb21wbGV0ZWQnKSBlbHNlICdjYW5jZWxsZWQnCgoKZGVmIG1hbnVhbChwb29sLCBhY3Rpb24sIGlwPU5vbmUsIHRhcmdldD1Ob25lLCBub3c9Tm9uZSk6CiAgICBub3cgPSB0aW1lLnRpbWUoKSBpZiBub3cgaXMgTm9uZSBlbHNlIG5vdwogICAgaWYgYWN0aW9uIGluICgncGF1c2UnLCAncmVzdW1lJyk6CiAgICAgICAgcG9vbFsncGF1c2VkJ10gPSBhY3Rpb24gPT0gJ3BhdXNlJwogICAgICAgIGlmIGFjdGlvbiA9PSAncGF1c2UnOgogICAgICAgICAgICBmb3IgaXRlbSBpbiBwb29sWydpbnRlbnRzJ106CiAgICAgICAgICAgICAgICBpZiBpdGVtWydzdGF0dXMnXSA9PSAncGVuZGluZycgYW5kIGl0ZW1bJ2FjdG9yJ10gPT0gJ2F1dG9tYXRpYyc6CiAgICAgICAgICAgICAgICAgICAgY2FuY2VsKGl0ZW0pCiAgICAgICAgZXZlbnQocG9vbCwgYWN0aW9uLCBub3cpCiAgICAgICAgcmV0dXJuCiAgICBpZiBpcCBub3QgaW4gcG9vbFsnYWRkcmVzc2VzJ106CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcignSVAg5LiN5Zyo5bey5Y+R546w5Zyw5Z2A5rGg5LitJykKICAgIGVudHJ5ID0gcG9vbFsnYWRkcmVzc2VzJ11baXBdCiAgICBpZiBhY3Rpb24gaW4gKCdsb2NrJywgJ3VubG9jaycpOgogICAgICAgIGVudHJ5Wydsb2NrZWQnXSA9IGFjdGlvbiA9PSAnbG9jaycKICAgICAgICBpZiBhY3Rpb24gPT0gJ2xvY2snOgogICAgICAgICAgICBmb3IgaXRlbSBpbiBwb29sWydpbnRlbnRzJ106CiAgICAgICAgICAgICAgICBpZiBpdGVtWydzdGF0dXMnXSA9PSAncGVuZGluZycgYW5kIGlwIGluIChpdGVtWydvbGQnXSwgaXRlbVsnbmV3J10pOgogICAgICAgICAgICAgICAgICAgIGNhbmNlbChpdGVtKQogICAgICAgIGV2ZW50KHBvb2wsIGFjdGlvbiwgbm93LCBpcD1pcCkKICAgICAgICByZXR1cm4KICAgIGlmIGVudHJ5LmdldCgnbG9ja2VkJyk6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcign5YWI6Kej6Zmk5Lq65bel6ZSB5a6aJykKICAgIGlmIGFjdGlvbiBub3QgaW4gKCdlbmFibGUnLCAnZGlzYWJsZScsICdyZXBsYWNlJyk6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcign5pyq55+l5pON5L2cJykKICAgIGlmIGFjdGlvbiBpbiAoJ2VuYWJsZScsICdyZXBsYWNlJyk6CiAgICAgICAgY2FuZGlkYXRlID0gaXAgaWYgYWN0aW9uID09ICdlbmFibGUnIGVsc2UgdGFyZ2V0CiAgICAgICAgaWYgY2FuZGlkYXRlIG5vdCBpbiBwb29sWydhZGRyZXNzZXMnXSBvciBub3QgZWxpZ2libGUocG9vbFsnYWRkcmVzc2VzJ11bY2FuZGlkYXRlXSwgbm93KToKICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJvcign55uu5qCH5b+F6aG75piv5b2T5YmN6aqM6K+B6YCa6L+H5LiU5pyq6ZSB5a6a55qE5aSH55So5YWs572RIElQJykKICAgIGlmIGFjdGlvbiA9PSAncmVwbGFjZScgYW5kIGVudHJ5Wydtb2RlJ10gIT0gJ2FjdGl2ZSc6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcign5Y+q5Y+v5pu/5o2i5ZCv55So5Lit55qE5YWl5Y+jJykKICAgIHRvdWNoZWQgPSB7aXAsIHRhcmdldH0gLSB7Tm9uZX0KICAgIGlmIGFueShpdGVtWydzdGF0dXMnXT09J2NsZWFudXBfcmVxdWlyZWQnIGFuZCB0b3VjaGVkLmludGVyc2VjdGlvbih7aXRlbVsnb2xkJ10saXRlbVsnbmV3J119KQogICAgICAgICAgIGZvciBpdGVtIGluIHBvb2xbJ2ludGVudHMnXSk6CiAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCflhbPogZTmk43kvZzlsJrpnIDmuIXnkIbvvIzor7flhYjlrozmiJDmgaLlpI0nKQogICAgaWYgYW55KGl0ZW1bJ3N0YXR1cyddPT0ncGVuZGluZycgYW5kIGl0ZW0uZ2V0KCdjb21wbGV0ZWQnKSBhbmQgdG91Y2hlZC5pbnRlcnNlY3Rpb24oe2l0ZW1bJ29sZCddLGl0ZW1bJ25ldyddfSkKICAgICAgICAgICBmb3IgaXRlbSBpbiBwb29sWydpbnRlbnRzJ10pOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcign5YWz6IGU5pON5L2c5bey5byA5aeL5omn6KGM77yM6K+35YWI5pqC5YGc5bm25a6M5oiQ5oGi5aSNJykKICAgIGZvciBpdGVtIGluIHBvb2xbJ2ludGVudHMnXToKICAgICAgICBpZiBpdGVtWydzdGF0dXMnXSA9PSAncGVuZGluZycgYW5kIHRvdWNoZWQuaW50ZXJzZWN0aW9uKHtpdGVtWydvbGQnXSwgaXRlbVsnbmV3J119KToKICAgICAgICAgICAgY2FuY2VsKGl0ZW0pCiAgICBlbnF1ZXVlKHBvb2wsIGFjdGlvbiwgaXAgaWYgYWN0aW9uICE9ICdlbmFibGUnIGVsc2UgTm9uZSwKICAgICAgICAgICAgdGFyZ2V0IGlmIGFjdGlvbiA9PSAncmVwbGFjZScgZWxzZSBpcCBpZiBhY3Rpb24gPT0gJ2VuYWJsZScgZWxzZSBOb25lLCBub3csICdtYW51YWwnKQo=', 'ip_pool_cli.py': 'IiIiTG9jYWwgSVAtcG9vbCBvcGVyYXRvci4gUGxhbnMgYXJlIGV4cGxpY2l0OyBubyB1bmltcGxlbWVudGVkIGFwcGx5IGNvbW1hbmQuIiIiCmltcG9ydCBhcmdwYXJzZQppbXBvcnQgY29udGV4dGxpYgppbXBvcnQgZmNudGwKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgc3lzCmltcG9ydCB0aW1lCmltcG9ydCBzaHV0aWwKaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IGlwX3Bvb2wKZnJvbSBpbnN0YWxsZXIgaW1wb3J0IGF0b21pYwoKUk9PVCA9IFBhdGgoJy92YXIvbGliL3doYWxlbm9kZS1pbnN0YWxsZXInKQoKCmRlZiBpbnN0YWxsX3dhdGNoKCk6CiAgICAiIiJJbnN0YWxsIG9ubHkgdGhlIGxvY2FsIGRpc2NvdmVyeSB0aW1lciwgbmV2ZXIgYSBwcml2aWxlZ2VkIHBhbmVsIHRva2VuLiIiIgogICAgZGVzdGluYXRpb249UGF0aCgnL29wdC93aGFsZW5vZGUvaXAtcG9vbCcpCiAgICBmaWxlcz0oJ2luc3RhbGxlci5weScsJ2VwaGVtZXJhbF9wb3J0cy5weScsJ2lwX3Bvb2wucHknLCdpcF9wb29sX2NsaS5weScsJ2lwX3Bvb2xfdHJhbnNhY3Rpb24ucHknKQogICAgc291cmNlPVBhdGgoX19maWxlX18pLnJlc29sdmUoKS5wYXJlbnQKICAgICMgVmFsaWRhdGUgYWxsIGlucHV0cyBiZWZvcmUgbWFraW5nIGFueSBpbnN0YWxsYXRpb24gY2hhbmdlcy4KICAgIGNvbnRlbnQ9e25hbWU6KHNvdXJjZS9uYW1lKS5yZWFkX3RleHQoZW5jb2Rpbmc9J3V0ZjgnKSBmb3IgbmFtZSBpbiBmaWxlc30KICAgIGRlc3RpbmF0aW9uLm1rZGlyKHBhcmVudHM9VHJ1ZSxleGlzdF9vaz1UcnVlLG1vZGU9MG83MDApCiAgICBmb3IgbmFtZSxib2R5IGluIGNvbnRlbnQuaXRlbXMoKTphdG9taWMoZGVzdGluYXRpb24vbmFtZSxib2R5KQogICAgdW5pdD0nJydbVW5pdF0KRGVzY3JpcHRpb249V2hhbGVOb2RlIHB1YmxpYyBJUHY0IGRpc2NvdmVyeSAobm8gYXV0b21hdGljIHB1YmxpY2F0aW9uKQpXYW50cz1uZXR3b3JrLW9ubGluZS50YXJnZXQKQWZ0ZXI9bmV0d29yay1vbmxpbmUudGFyZ2V0CltTZXJ2aWNlXQpUeXBlPW9uZXNob3QKRXhlY1N0YXJ0PS91c3IvYmluL3B5dGhvbjMgL29wdC93aGFsZW5vZGUvaXAtcG9vbC9pcF9wb29sX2NsaS5weSBzY2FuClVNYXNrPTAwNzcKRW52aXJvbm1lbnQ9UFlUSE9ORE9OVFdSSVRFQllURUNPREU9MQpDUFVRdW90YT0yMCUKTWVtb3J5TWF4PTEyOE0KVGFza3NNYXg9MTYKVGltZW91dFN0YXJ0U2VjPTYwMApOb05ld1ByaXZpbGVnZXM9eWVzClByb3RlY3RTeXN0ZW09c3RyaWN0ClByb3RlY3RIb21lPXllcwpQcml2YXRlVG1wPXllcwpSZWFkV3JpdGVQYXRocz0vdmFyL2xpYi93aGFsZW5vZGUtaW5zdGFsbGVyCicnJwogICAgdGltZXI9JycnW1VuaXRdCkRlc2NyaXB0aW9uPUNoZWNrIFdoYWxlTm9kZSBwdWJsaWMgSVB2NCBwb29sIGFmdGVyIGJvb3QgYW5kIGV2ZXJ5IGZpdmUgbWludXRlcwpbVGltZXJdCk9uQm9vdFNlYz0zbWluCk9uVW5pdEluYWN0aXZlU2VjPTVtaW4KUmFuZG9taXplZERlbGF5U2VjPTE1cwpVbml0PXdoYWxlbm9kZS1pcC1wb29sLnNlcnZpY2UKW0luc3RhbGxdCldhbnRlZEJ5PXRpbWVycy50YXJnZXQKJycnCiAgICBhdG9taWMoJy9ldGMvc3lzdGVtZC9zeXN0ZW0vd2hhbGVub2RlLWlwLXBvb2wuc2VydmljZScsdW5pdCwwbzY0NCkKICAgIGF0b21pYygnL2V0Yy9zeXN0ZW1kL3N5c3RlbS93aGFsZW5vZGUtaXAtcG9vbC50aW1lcicsdGltZXIsMG82NDQpCiAgICBzdWJwcm9jZXNzLnJ1bihbJ3N5c3RlbWN0bCcsJ2RhZW1vbi1yZWxvYWQnXSxjaGVjaz1UcnVlLHRpbWVvdXQ9MzApCiAgICBzdWJwcm9jZXNzLnJ1bihbJ3N5c3RlbWN0bCcsJ2VuYWJsZScsJy0tbm93Jywnd2hhbGVub2RlLWlwLXBvb2wudGltZXInXSxjaGVjaz1UcnVlLHRpbWVvdXQ9MzApCgoKQGNvbnRleHRsaWIuY29udGV4dG1hbmFnZXIKZGVmIGxvY2tlZChyb290KToKICAgIHJvb3QubWtkaXIobW9kZT0wbzcwMCwgcGFyZW50cz1UcnVlLCBleGlzdF9vaz1UcnVlKQogICAgd2l0aCAocm9vdC8nbG9jaycpLm9wZW4oJ2EnKSBhcyBsb2NrOgogICAgICAgIHRyeToKICAgICAgICAgICAgZmNudGwuZmxvY2sobG9jaywgZmNudGwuTE9DS19FWCB8IGZjbnRsLkxPQ0tfTkIpCiAgICAgICAgZXhjZXB0IEJsb2NraW5nSU9FcnJvcjoKICAgICAgICAgICAgcmFpc2UgUnVudGltZUVycm9yKCflronoo4XmiJYgSVAg566h55CG5Lu75Yqh5q2j5Zyo5omn6KGM77yM6K+356iN5ZCO6YeN6K+VJykgZnJvbSBOb25lCiAgICAgICAgeWllbGQKCgpkZWYgbG9hZChyb290KToKICAgIHBhdGggPSByb290LydpcC1wb29sLmpzb24nCiAgICBpZiBwYXRoLmV4aXN0cygpOgogICAgICAgIHJlc3VsdCA9IGpzb24ubG9hZHMocGF0aC5yZWFkX3RleHQoKSkKICAgICAgICBpZiByZXN1bHQuZ2V0KCdzY2hlbWEnKSAhPSAxOgogICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCflnLDlnYDmsaDniYjmnKzkuI3lhbzlrrknKQogICAgICAgIHJldHVybiByZXN1bHQKICAgIGxlZ2FjeSA9IHJvb3QvJ3N0YXRlLmpzb24nCiAgICBvbGQgPSBqc29uLmxvYWRzKGxlZ2FjeS5yZWFkX3RleHQoKSkgaWYgbGVnYWN5LmV4aXN0cygpIGVsc2Uge30KICAgIHJlc3VsdCA9IGlwX3Bvb2wubmV3X3Bvb2wob2xkLmdldCgnbm9uY2UnKSkKICAgIGlmIG9sZC5nZXQoJ2lkcycpIGFuZCBpcF9wb29sLnB1YmxpY19pcHY0KG9sZC5nZXQoJ2hvc3QnKSk6CiAgICAgICAgcmVzdWx0WydhZGRyZXNzZXMnXVtvbGRbJ2hvc3QnXV0gPSB7CiAgICAgICAgICAgICdtb2RlJzogJ2FjdGl2ZScsICdsb2NrZWQnOiBGYWxzZSwgJ21pc3NpbmdfY291bnQnOiAwLAogICAgICAgICAgICAnbGVnYWN5X2lkcyc6IG9sZFsnaWRzJ10sICdsZWdhY3knOiBUcnVlLCAnZWdyZXNzJzogJ3Vua25vd24nLCAncHJlc2VudCc6IE5vbmV9CiAgICByZXR1cm4gcmVzdWx0CgoKZGVmIG1haW4oYXJndj1Ob25lKToKICAgIHBhcnNlciA9IGFyZ3BhcnNlLkFyZ3VtZW50UGFyc2VyKGRlc2NyaXB0aW9uPSflhaznvZEgSVAg5rGg77ya5omr5o+P44CB54q25oCB5LiO5pON5L2c6K6h5YiS77yI5bCa5LiN6Ieq5Yqo5L+u5pS56Z2i5p2/77yJJykKICAgIHBhcnNlci5hZGRfYXJndW1lbnQoJ2FjdGlvbicsIGNob2ljZXM9WydzdGF0dXMnLCdzY2FuJywnZW5hYmxlJywnZGlzYWJsZScsJ3JlcGxhY2UnLCdsb2NrJywndW5sb2NrJywncGF1c2UnLCdyZXN1bWUnLCdoaXN0b3J5JywnaW5zdGFsbC13YXRjaCcsJ3N0b3Atd2F0Y2gnXSkKICAgIHBhcnNlci5hZGRfYXJndW1lbnQoJ2lwJywgbmFyZ3M9Jz8nKQogICAgcGFyc2VyLmFkZF9hcmd1bWVudCgndGFyZ2V0JywgbmFyZ3M9Jz8nKQogICAgcGFyc2VyLmFkZF9hcmd1bWVudCgnLS1pbnRlcmZhY2UnLCBhY3Rpb249J2FwcGVuZCcsIGhlbHA9J+mZkOWItuaJq+aPj+e9keWNoe+8jOWPr+mHjeWkjeS8oOWFpScpCiAgICBhcmdzID0gcGFyc2VyLnBhcnNlX2FyZ3MoYXJndikKICAgIGlmIG9zLmdldGV1aWQoKSAhPSAwOgogICAgICAgIHJhaXNlIFJ1bnRpbWVFcnJvcign6K+35LulIHJvb3Qg6L+Q6KGMJykKICAgIG9zLnVtYXNrKDBvMDc3KQogICAgaWYgYXJncy5hY3Rpb24gaW4gKCdzdGF0dXMnLCAnaGlzdG9yeScpOgogICAgICAgICMgUmVhZC1vbmx5IGluc3BlY3Rpb24gZG9lcyBub3QgY3JlYXRlIGEgcG9vbCBvciBhY3F1aXJlIGEgd3JpdGUgbG9jay4KICAgICAgICBkYXRhID0gbG9hZChST09UKQogICAgICAgIHByaW50KGpzb24uZHVtcHMoZGF0YVsnaGlzdG9yeSddIGlmIGFyZ3MuYWN0aW9uID09ICdoaXN0b3J5JyBlbHNlIGRhdGEsZW5zdXJlX2FzY2lpPUZhbHNlLGluZGVudD0yKSkKICAgICAgICByZXR1cm4KICAgIGlmIGFyZ3MuYWN0aW9uIGluICgnZW5hYmxlJywnZGlzYWJsZScsJ3JlcGxhY2UnLCdsb2NrJywndW5sb2NrJykgYW5kIG5vdCBhcmdzLmlwOgogICAgICAgIHBhcnNlci5lcnJvcign6K+l5pON5L2c6ZyA6KaB5oyH5a6aIElQJykKICAgIGlmIGFyZ3MuYWN0aW9uPT0ncmVwbGFjZScgYW5kIG5vdCBhcmdzLnRhcmdldDoKICAgICAgICBwYXJzZXIuZXJyb3IoJ3JlcGxhY2Ug6ZyA6KaB5penIElQIOWSjOaWsCBJUCcpCiAgICB3aXRoIGxvY2tlZChST09UKToKICAgICAgICBpZiBhcmdzLmFjdGlvbj09J2luc3RhbGwtd2F0Y2gnOgogICAgICAgICAgICBpbnN0YWxsX3dhdGNoKCkKICAgICAgICAgICAgcHJpbnQoJ+W8gOacuuS4juWumuaXtuWPkeeOsOW3suWQr+eUqO+8m+atpOeJiOacrOS7heS/neWtmOaTjeS9nOiuoeWIku+8jOS4jeiHquWKqOWPkeW4g+aIluabtOaNouiKgueCueOAgicpCiAgICAgICAgICAgIHJldHVybgogICAgICAgIGlmIGFyZ3MuYWN0aW9uPT0nc3RvcC13YXRjaCc6CiAgICAgICAgICAgIHN1YnByb2Nlc3MucnVuKFsnc3lzdGVtY3RsJywnZGlzYWJsZScsJy0tbm93Jywnd2hhbGVub2RlLWlwLXBvb2wudGltZXInXSxjaGVjaz1UcnVlLHRpbWVvdXQ9MzApCiAgICAgICAgICAgIHByaW50KCflkI7nu63lrprml7bmo4Dmn6Xlt7LlgZznlKjvvJvlvZPliY3mk43kvZzku43lj5fnu5/kuIDplIHkv53miqTjgIInKQogICAgICAgICAgICByZXR1cm4KICAgICAgICBkYXRhID0gbG9hZChST09UKQogICAgICAgIGlmIGFyZ3MuYWN0aW9uID09ICdzY2FuJzoKICAgICAgICAgICAgZm91bmQgPSBpcF9wb29sLnNjYW4oYXJncy5pbnRlcmZhY2UpCiAgICAgICAgICAgIGlmIGxlbihmb3VuZCk+MzI6CiAgICAgICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+WPkeeOsOi2hei/hyAzMiDkuKrlhaznvZHlnLDlnYDvvIzor7fmjInnvZHljaHnvKnlsI/mo4Dmn6XojIPlm7QnKQogICAgICAgICAgICByZXN1bHRzPXt9CiAgICAgICAgICAgIGZvciBpcCBpbiBmb3VuZDoKICAgICAgICAgICAgICAgIHRyeTpyZXN1bHRzW2lwXT1pcF9wb29sLnZlcmlmeV9lZ3Jlc3MoaXApCiAgICAgICAgICAgICAgICBleGNlcHQgKFRpbWVvdXRFcnJvciwgaXBfcG9vbC5zdWJwcm9jZXNzLlRpbWVvdXRFeHBpcmVkKToKICAgICAgICAgICAgICAgICAgICByZXN1bHRzW2lwXT17J3N0YXR1cyc6J3Vua25vd24nfQogICAgICAgICAgICBib290PVBhdGgoJy9wcm9jL3N5cy9rZXJuZWwvcmFuZG9tL2Jvb3RfaWQnKS5yZWFkX3RleHQoKS5zdHJpcCgpCiAgICAgICAgICAgIHVwdGltZT1mbG9hdChQYXRoKCcvcHJvYy91cHRpbWUnKS5yZWFkX3RleHQoKS5zcGxpdCgpWzBdKQogICAgICAgICAgICBkYXRhPWlwX3Bvb2wucmVjb25jaWxlKGRhdGEsZm91bmQscmVzdWx0cyx0aW1lLnRpbWUoKSxib290LHVwdGltZSkKICAgICAgICBlbHNlOgogICAgICAgICAgICBpcF9wb29sLm1hbnVhbChkYXRhLGFyZ3MuYWN0aW9uLGFyZ3MuaXAsYXJncy50YXJnZXQpCiAgICAgICAgYXRvbWljKFJPT1QvJ2lwLXBvb2wuanNvbicsanNvbi5kdW1wcyhkYXRhLGVuc3VyZV9hc2NpaT1GYWxzZSxpbmRlbnQ9MikpCiAgICAgICAgcHJpbnQoanNvbi5kdW1wcyh7J3NhdmVkJzpUcnVlLCdhcHBsaWVkJzpGYWxzZSwncG9vbCc6ZGF0YX0sZW5zdXJlX2FzY2lpPUZhbHNlLGluZGVudD0yKSkKCgppZiBfX25hbWVfXz09J19fbWFpbl9fJzoKICAgIHRyeTptYWluKCkKICAgIGV4Y2VwdCAoRXhjZXB0aW9uLEtleWJvYXJkSW50ZXJydXB0KSBhcyBlcnJvcjoKICAgICAgICBwcmludChzdHIoZXJyb3IpIGlmIGlzaW5zdGFuY2UoZXJyb3IsKFZhbHVlRXJyb3IsUnVudGltZUVycm9yKSkgZWxzZSB0eXBlKGVycm9yKS5fX25hbWVfXyxmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgc3lzLmV4aXQoMSkK', 'ip_pool_transaction.py': 'IiIiUmVzdW1hYmxlIGFwcGxpY2F0aW9uIGNvbnRyYWN0LiBBZGFwdGVyIG1ldGhvZHMgbXVzdCByZWNvbmNpbGUgYnkgaW50ZW50IElELgoKUGVyc2lzdCBlYWNoIHN1Y2Nlc3NmdWwgc3RlcCBiZWZvcmUgdGhlIG5leHQuIEEgZmFpbGVkL2FtYmlndW91cyBjYWxsIGxlYXZlcyB0aGUKc3RlcCBwZW5kaW5nOiB0aGUgYWRhcHRlciByZWFkcyBiYWNrIG93bmVkIHJlc291cmNlcyBiZWZvcmUgYW55IHJlcGVhdGVkIHdyaXRlLgoiIiIKaW1wb3J0IHRpbWUKClNURVBTID0gewogICAgJ2VuYWJsZSc6ICgncHJlcGFyZScsICd2ZXJpZnknLCAncHVibGlzaCcsICdjb25maXJtJyksCiAgICAncmVwbGFjZSc6ICgncHJlcGFyZScsICd2ZXJpZnknLCAncHVibGlzaCcsICdjb25maXJtJywgJ2hpZGVfb2xkJywgJ3N0b3Bfb2xkJyksCiAgICAnZGlzYWJsZSc6ICgnaGlkZV9vbGQnLCAnY29uZmlybV9oaWRkZW4nLCAnc3RvcF9vbGQnKSwKICAgICdoaWRlJzogKCdoaWRlX29sZCcsICdjb25maXJtX2hpZGRlbicsICdzdG9wX29sZCcpLAp9CgoKZGVmIGV4ZWN1dGUocG9vbCwgaW50ZW50X2lkLCBhZGFwdGVyLCBwZXJzaXN0LCBub3c9Tm9uZSk6CiAgICAiIiJDYWxsZXIgaG9sZHMgdGhlIGluc3RhbGxlciBsb2NrIGZvciB0aGUgZW50aXJlIHRyYW5zYWN0aW9uLgoKICAgIGFkYXB0ZXIudmFsaWRhdGUgY2hlY2tzIGN1cnJlbnQgSVAgb3duZXJzaGlwLCBzb3VyY2UtYm91bmQgZWdyZXNzLCByZXNvdXJjZQogICAgb3duZXJzaGlwIGFuZCBzZXJ2ZXItc2NvcGVkIGF1dGhvcml0eS4gQWxsIHN0ZXBzIGFyZSBpZGVtcG90ZW50L3JlYWQtYmFjay4KICAgIGNvbmZpcm0gdmVyaWZpZXMgcHVibGljYXRpb24gYW5kIGFjdHVhbCBleHRlcm5hbCB0cmFuc2ZlciBiZWZvcmUgcmV0aXJpbmcgb2xkLgogICAgIiIiCiAgICBub3cgPSB0aW1lLnRpbWUoKSBpZiBub3cgaXMgTm9uZSBlbHNlIG5vdwogICAgaW50ZW50ID0gbmV4dCh4IGZvciB4IGluIHBvb2xbJ2ludGVudHMnXSBpZiB4WydpZCddID09IGludGVudF9pZCkKICAgIGlmIGludGVudFsnc3RhdHVzJ10gIT0gJ3BlbmRpbmcnOgogICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgaW50ZW50WydhY3RvciddPT0nYXV0b21hdGljJyBhbmQgcG9vbFsncGF1c2VkJ106CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBpZiBhbnkocG9vbFsnYWRkcmVzc2VzJ11baXBdLmdldCgnbG9ja2VkJykgZm9yIGlwIGluIChpbnRlbnRbJ29sZCddLGludGVudFsnbmV3J10pIGlmIGlwKToKICAgICAgICByZXR1cm4gRmFsc2UKICAgIGFkYXB0ZXIudmFsaWRhdGUocG9vbCwgaW50ZW50KQogICAgY29tcGxldGVkPWludGVudC5zZXRkZWZhdWx0KCdjb21wbGV0ZWQnLFtdKQogICAgZm9yIHN0ZXAgaW4gU1RFUFNbaW50ZW50WydhY3Rpb24nXV06CiAgICAgICAgaWYgc3RlcCBpbiBjb21wbGV0ZWQ6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgIyBBbiBleGNlcHRpb24gaGVyZSBtdXN0IG5vdCBzZXQgY29tcGxldGlvbiBvciByZXRpcmUgdGhlIG9sZCBlbnRyeS4KICAgICAgICBnZXRhdHRyKGFkYXB0ZXIsc3RlcCkocG9vbCxpbnRlbnQpCiAgICAgICAgY29tcGxldGVkLmFwcGVuZChzdGVwKQogICAgICAgIHBlcnNpc3QocG9vbCkKICAgIGlmIGludGVudFsnb2xkJ106CiAgICAgICAgb2xkPXBvb2xbJ2FkZHJlc3NlcyddW2ludGVudFsnb2xkJ11dCiAgICAgICAgb2xkWydtb2RlJ109J2Rpc2FibGVkJyBpZiBpbnRlbnRbJ2FjdGlvbiddPT0nZGlzYWJsZScgZWxzZSAncmV0aXJlZCcKICAgICAgICBvbGRbJ2Nvb2xkb3duX3VudGlsJ109bm93KzM2MDAKICAgIGlmIGludGVudFsnbmV3J106CiAgICAgICAgbmV3PXBvb2xbJ2FkZHJlc3NlcyddW2ludGVudFsnbmV3J11dCiAgICAgICAgbmV3Wydtb2RlJ109J2FjdGl2ZScKICAgICAgICBuZXdbJ2Nvb2xkb3duX3VudGlsJ109bm93KzM2MDAKICAgIGludGVudC51cGRhdGUoc3RhdHVzPSdjb21wbGV0ZScsY29tcGxldGVkX2F0PW5vdykKICAgICMgQm91bmQgY29tcGxldGVkIGhpc3RvcnksIGJ1dCBuZXZlciBkaXNjYXJkIHBlbmRpbmcgcmVjb3Zlcnkgam91cm5hbHMuCiAgICB1bmZpbmlzaGVkPXsncGVuZGluZycsJ2NsZWFudXBfcmVxdWlyZWQnfQogICAgZmluaXNoZWQ9W3ggZm9yIHggaW4gcG9vbFsnaW50ZW50cyddIGlmIHhbJ3N0YXR1cyddIG5vdCBpbiB1bmZpbmlzaGVkXVstMTAwOl0KICAgIHBvb2xbJ2ludGVudHMnXT1beCBmb3IgeCBpbiBwb29sWydpbnRlbnRzJ10gaWYgeFsnc3RhdHVzJ10gaW4gdW5maW5pc2hlZF0rZmluaXNoZWQKICAgIHBlcnNpc3QocG9vbCkKICAgIHJldHVybiBUcnVlCg==', 'node_menu.py': 'IiIiVW5pZmllZCBvcGVyYXRvciBtZW51LiBSZXVzZXMgZXhpc3Rpbmcgb3BlcmF0aW9ucyB3aXRob3V0IGNsYWltaW5nIHBsYW5zIGFwcGx5LiIiIgppbXBvcnQganNvbgppbXBvcnQgc3lzCmZyb20gcGF0aGxpYiBpbXBvcnQgUGF0aAppbXBvcnQgaW5zdGFsbGVyIGFzIGkKaW1wb3J0IGlwX3Bvb2xfY2xpIGFzIHBvb2wKaW1wb3J0IHNjYW5fcHVibGljX2lwcyBhcyBzY2FubmVyCgoKZGVmIG11bHRpX2lwX3ByZXNlbnQoKToKICAgIHJldHVybiBpLmhhc19hZGRpdGlvbmFsX2lwX2luc3RhbmNlcygpCgoKZGVmIHN0YXR1cygpOgogICAgaS5tYWluKFsnLS1zdGF0dXMnXSkKICAgIGZvciBzZXJ2aWNlIGluICgnd2hhbGVub2RlLnNlcnZpY2UnLCd6YWJiaXgtYWdlbnQyLnNlcnZpY2UnLCd3aGFsZW5vZGUtaXAtcG9vbC50aW1lcicpOgogICAgICAgIHA9aS5ydW4oJ3N5c3RlbWN0bCcsJ3Nob3cnLHNlcnZpY2UsJy1wJywnTG9hZFN0YXRlJywnLXAnLCdBY3RpdmVTdGF0ZScsJy1wJywnTWFpblBJRCcsY2hlY2s9RmFsc2UpCiAgICAgICAgcHJpbnQoc2VydmljZSsnXG4nK3Auc3Rkb3V0LnN0cmlwKCkpCiAgICBmb3IgcGF0aCBpbiBzb3J0ZWQoUGF0aCgnL2V0Yy9zeXN0ZW1kL3N5c3RlbScpLmdsb2IoJ3doYWxlbm9kZS1pcC0qLnNlcnZpY2UnKSk6CiAgICAgICAgaWYgcGF0aC5uYW1lPT0nd2hhbGVub2RlLWlwLXBvb2wuc2VydmljZSc6Y29udGludWUKICAgICAgICBwcmludChwYXRoLm5hbWUrJ1xuJytpLnJ1bignc3lzdGVtY3RsJywnc2hvdycscGF0aC5uYW1lLCctcCcsJ0FjdGl2ZVN0YXRlJywnLXAnLCdNYWluUElEJyxjaGVjaz1GYWxzZSkuc3Rkb3V0LnN0cmlwKCkpCiAgICBwcmludCgn6L+Z6YeM5pi+56S65pys5py65pyN5Yqh54q25oCB77yb6ZuG5Lit55uR5o6n5paw6bKc5pWw5o2u5ZKM5YWs572R5Y+v55So5oCn6ZyA5Y+m5aSW6aqM6K+B44CCJykKCgpkZWYgcGFuZWxfbWVudShiYXNlKToKICAgIHByaW50KCcxIOmakOiXj+WOn+WuieijheWZqOiKgueCue+8iOWBnOatouiuoumYheS4i+WPke+8iVxuMiDmgaLlpI3ljp/lronoo4XlmajoioLngrnmmL7npLpcbjAg6L+U5ZueJykKICAgIGlmIG11bHRpX2lwX3ByZXNlbnQoKToKICAgICAgICBwcmludCgn5pys5py65pyJ6ZmE5YqgIElQIOWunuS+i++8muatpOWkhOS7heeuoeeQhuWOn+WuieijheWZqOiusOW9leS4reeahOiKgueCue+8jOS4jeWMheaLrOmZhOWKoCBJUOOAgicpCiAgICBjaG9pY2U9aS5wcm9tcHQoJ+ivt+mAieaLqScsJzAnKQogICAgZmxhZz17JzEnOictLWhpZGUnLCcyJzonLS1zaG93J30uZ2V0KGNob2ljZSkKICAgIGlmIGZsYWc6aS5tYWluKGJhc2UrW2ZsYWddKQoKCmRlZiBpcF9tZW51KCk6CiAgICB3aGlsZSBUcnVlOgogICAgICAgIHByaW50KCdcbuWFrOe9kSBJUCDnrqHnkIZcbjEg5omr5o+P5YWs572RIElQ77yI5Y+q6K+777yJXG4yIOWIt+aWsOacrOacuiBJUCDmsaBcbjMg5p+l55yLIElQIOaxoOS4juaTjeS9nOiusOW9lVxuNCDplIHlrpogSVBcbjUg6Kej6Zmk6ZSB5a6aXG42IOW8gOWQr+W8gOacui/mr4/kupTliIbpkp/miavmj49cbjcg5YWz6Zet5a6a5pe25omr5o+PXG44IOaWsOWini/mm7TmjaIgSVAg55qE5b2T5YmN5pSv5oyB6IyD5Zu0XG4wIOi/lOWbnicpCiAgICAgICAgY2hvaWNlPWkucHJvbXB0KCfor7fpgInmi6knLCcwJykKICAgICAgICBpZiBjaG9pY2U9PScwJzpyZXR1cm4KICAgICAgICBpZiBjaG9pY2U9PScxJzpzY2FubmVyLm1haW4oW10pCiAgICAgICAgZWxpZiBjaG9pY2U9PScyJzpwb29sLm1haW4oWydzY2FuJ10pCiAgICAgICAgZWxpZiBjaG9pY2U9PSczJzpwb29sLm1haW4oWydzdGF0dXMnXSk7cG9vbC5tYWluKFsnaGlzdG9yeSddKQogICAgICAgIGVsaWYgY2hvaWNlIGluICgnNCcsJzUnKToKICAgICAgICAgICAgaXA9aS5wcm9tcHQoJ+ivt+i+k+WFpSBJUO+8iDAg6L+U5Zue77yJJywnMCcpCiAgICAgICAgICAgIGlmIGlwIT0nMCc6cG9vbC5tYWluKFsnbG9jaycgaWYgY2hvaWNlPT0nNCcgZWxzZSAndW5sb2NrJyxpcF0pCiAgICAgICAgZWxpZiBjaG9pY2U9PSc2Jzpwb29sLm1haW4oWydpbnN0YWxsLXdhdGNoJ10pCiAgICAgICAgZWxpZiBjaG9pY2U9PSc3Jzpwb29sLm1haW4oWydzdG9wLXdhdGNoJ10pCiAgICAgICAgZWxpZiBjaG9pY2U9PSc4JzoKICAgICAgICAgICAgcHJpbnQoJ+aWsOWiniBJUO+8muWFiOeUsei/kOiQpeWVhuWIhumFjeW5tue7keWumue9keWNoe+8jOWGjemAieaLqSAxIOaJq+aPj+mqjOivgeOAglxuJwogICAgICAgICAgICAgICAgICAn5pu05o2iIElQ77ya5YWI6aqM6K+B5pawIElQ77yM5YaN5a6M5oiQ54us56uL6IqC54K56YWN572u44CB6Z2i5p2/L+WIhue7hOWQjOatpeWSjOWunumZheS8oOi+k+mqjOaUtu+8jOacgOWQjuaSpOS4i+aXp+WFpeWPo+OAglxuJwogICAgICAgICAgICAgICAgICAn5pys54mI5pys5pSv5oyB6Ieq5Yqo5Y+R546w5LiO5omL5Yqo6ZSB5a6a77yb6YCa55So5om56YeP5bu66IqC54K55ZKM6Ieq5Yqo5pu/5o2i5omn6KGM5bCa5pyq5o6l6YCa44CCXG4nCiAgICAgICAgICAgICAgICAgICfmiavmj4/pgJrov4fmiJbliLfmlrAgSVAg5rGg5LiN5Lya5Yib5bu66IqC54K577yM5LiN5Lya6Ieq5Yqo5pu/5o2i546w5pyJ6IqC54K544CCJykKICAgICAgICBlbHNlOnByaW50KCfor7fovpPlhaXoj5zljZXkuK3nmoTmlbDlrZfjgIInKQoKCmRlZiBtYWluKGJhc2U9Tm9uZSk6CiAgICBiYXNlPWxpc3QoYmFzZSBvciBbXSkKICAgIGlmIGkub3MuZ2V0ZXVpZCgpIT0wOnJhaXNlIFJ1bnRpbWVFcnJvcign6K+35L2/55SoIHJvb3Qg5oiWIHN1ZG8g6L+Q6KGM566h55CG6I+c5Y2VJykKICAgICMgUmVqZWN0IGV4ZWN1dGlvbi1tb2RlIGZsYWdzOiBtZW51IG9wdGlvbnMgbXVzdCBzZWxlY3QgZXhhY3RseSBvbmUgb3BlcmF0aW9uLgogICAgZm9yYmlkZGVuPXsnLS1ub24taW50ZXJhY3RpdmUnLCctLXN0YXR1cycsJy0tY2hlY2snLCctLXBsYW4nLCctLXJldHVuZScsJy0taGlkZScsJy0tc2hvdycsJy0tdW5pbnN0YWxsJywnLS1yb2xsYmFjaycsJy0tcmVwb3J0LWZpbGUnLCctLXllcyd9CiAgICBpZiBhbnkodmFsdWUuc3BsaXQoJz0nLDEpWzBdIGluIGZvcmJpZGRlbiBmb3IgdmFsdWUgaW4gYmFzZSk6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcignLS1tZW51IOS4jeiDveS4juaJp+ihjOaooeW8j+WPguaVsOa3t+eUqO+8m+iHquWKqOWMluivt+ebtOaOpeS9v+eUqOWOn+WRveS7pOWPguaVsCcpCiAgICBpLnBhcnNlcigpLnBhcnNlX2FyZ3MoYmFzZSkKICAgIHdoaWxlIFRydWU6CiAgICAgICAgaW5zdGFsbGVkPShpLlJPT1QvJ3N0YXRlLmpzb24nKS5leGlzdHMoKQogICAgICAgIHByaW50KCdcbumyuOmxvOiKgueCueeuoeeQhlxuJysoJ+ajgOa1i+WIsOWOn+WuieijheWZqOiusOW9lScgaWYgaW5zdGFsbGVkIGVsc2UgJ+WwmuacquWPkeeOsOWOn+WuieijheWZqOiusOW9le+8jOW3suacieacjeWKoeS4jeS8muiiq+iHquWKqOaOpeeuoScpKQogICAgICAgIHByaW50KCcxIOWuieijheiKgueCuSAvIOe7p+e7reacquWujOaIkOeahOWuieijhVxuMiDmn6XnnIvoioLngrnkuI7nm5HmjqfnirbmgIFcbjMg5omr5o+P572R5Y2h5YWs572RIElQXG40IOWFrOe9kSBJUCDkuI7lvIDmnLrmiavmj4/nrqHnkIZcbjUg6ZqQ6JePIC8g5oGi5aSN5Y6f6IqC54K5XG42IOacrOacuuiviuaWrVxuNyDmjInlvZPliY0gQ1BVL+WGheWtmOmHjeaWsOiwg+WPglxuOCDljbjovb3ljp/lronoo4XlmajoioLngrlcbjAg6YCA5Ye6JykKICAgICAgICB0cnk6CiAgICAgICAgICAgIGNob2ljZT1pLnByb21wdCgn6K+36YCJ5oupJywnMCcpCiAgICAgICAgICAgIGlmIGNob2ljZT09JzAnOnJldHVybgogICAgICAgICAgICBpZiBjaG9pY2U9PScxJzppLm1haW4oYmFzZStbJy0tbm9uLWludGVyYWN0aXZlJ10gaWYgaW5zdGFsbGVkIGFuZCBqc29uLmxvYWRzKChpLlJPT1QvJ3N0YXRlLmpzb24nKS5yZWFkX3RleHQoKSkuZ2V0KCdwaGFzZScpPT0ncHVibGlzaGVkJyBlbHNlIGJhc2UpCiAgICAgICAgICAgIGVsaWYgY2hvaWNlPT0nMic6c3RhdHVzKCkKICAgICAgICAgICAgZWxpZiBjaG9pY2U9PSczJzpzY2FubmVyLm1haW4oW10pCiAgICAgICAgICAgIGVsaWYgY2hvaWNlPT0nNCc6aXBfbWVudSgpCiAgICAgICAgICAgIGVsaWYgY2hvaWNlPT0nNSc6cGFuZWxfbWVudShiYXNlKQogICAgICAgICAgICBlbGlmIGNob2ljZT09JzYnOmkubWFpbihbJy0tY2hlY2snXSkKICAgICAgICAgICAgZWxpZiBjaG9pY2U9PSc3JzoKICAgICAgICAgICAgICAgIHByaW50KCfpooTnrpflj5jljJblj6/og73nn63mmoLph43lkK/ljp/lkI7nq6/jgIInKQogICAgICAgICAgICAgICAgaWYgaS5wcm9tcHQoJ+i+k+WFpSAxIOaJp+ihjO+8jDAg6L+U5ZueJywnMCcpPT0nMSc6aS5tYWluKFsnLS1yZXR1bmUnXSkKICAgICAgICAgICAgZWxpZiBjaG9pY2U9PSc4JzoKICAgICAgICAgICAgICAgIGlmIG11bHRpX2lwX3ByZXNlbnQoKToKICAgICAgICAgICAgICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+ajgOa1i+WIsOmZhOWKoCBJUCDlrp7kvovvvIzml6fljbjovb3kvJrliKDpmaTlhbHnlKjmoLjlv4Mv6YWN572uL+ebkeaOp++8jOW3sumYu+atou+8m+mcgOWFiOWItuWumumAkOWunuS+i+WNuOi9veaTjeS9nCcpCiAgICAgICAgICAgICAgICBpLm1haW4oYmFzZStbJy0tdW5pbnN0YWxsJ10pCiAgICAgICAgICAgIGVsc2U6cHJpbnQoJ+ivt+i+k+WFpeiPnOWNleS4reeahOaVsOWtl+OAgicpCiAgICAgICAgZXhjZXB0IEtleWJvYXJkSW50ZXJydXB0OgogICAgICAgICAgICBwcmludCgnXG7lt7Llj5bmtojlvZPliY3oj5zljZXmk43kvZzvvIzov5Tlm57kuLvoj5zljZXjgIInKQogICAgICAgIGV4Y2VwdCAoUnVudGltZUVycm9yLFZhbHVlRXJyb3IpIGFzIGVycm9yOgogICAgICAgICAgICAjIEEgbWlzc2luZyBjb250cm9sbGluZyB0ZXJtaW5hbCBpcyBub3QgYSByZXRyeWFibGUgbWVudSBhY3Rpb24uCiAgICAgICAgICAgIGlmICfnu4jnq68nIGluIHN0cihlcnJvcik6cmFpc2UKICAgICAgICAgICAgcHJpbnQoJ+aTjeS9nOacquWujOaIkO+8micrc3RyKGVycm9yKSkKCmlmIF9fbmFtZV9fPT0nX19tYWluX18nOm1haW4oc3lzLmFyZ3ZbMTpdKQo=', 'scan_public_ips.py': 'IiIiU3RhbmRhbG9uZSwgcmVhZC1vbmx5IHB1YmxpYyBJUHY0IGludGVyZmFjZSBhbmQgc291cmNlLWVncmVzcyBzY2FubmVyLiIiIgppbXBvcnQgaXBhZGRyZXNzCmltcG9ydCBqc29uCmltcG9ydCBvcwppbXBvcnQgc2h1dGlsCmltcG9ydCBzdWJwcm9jZXNzCgojIERlbGliZXJhdGVseSBzdGFibGUgYWNyb3NzIFB5dGhvbiB2ZXJzaW9ucy4gQ29uc2VydmF0aXZlbHkgZXhjbHVkZSBzcGVjaWFsLXVzZQojIHNwYWNlLCBpbmNsdWRpbmcgcHJvdG9jb2wgYXNzaWdubWVudHMgYW5kIGRlcHJlY2F0ZWQgdHJhbnNpdGlvbiBtZWNoYW5pc21zLgpFWENMVURFRCA9IHR1cGxlKGlwYWRkcmVzcy5pcF9uZXR3b3JrKHgpIGZvciB4IGluICgKICAgICcwLjAuMC4wLzgnLCAnMTAuMC4wLjAvOCcsICcxMDAuNjQuMC4wLzEwJywgJzEyNy4wLjAuMC84JywKICAgICcxNjkuMjU0LjAuMC8xNicsICcxNzIuMTYuMC4wLzEyJywgJzE5Mi4wLjAuMC8yNCcsICcxOTIuMC4yLjAvMjQnLAogICAgJzE5Mi44OC45OS4wLzI0JywgJzE5Mi4xNjguMC4wLzE2JywgJzE5OC4xOC4wLjAvMTUnLAogICAgJzE5OC41MS4xMDAuMC8yNCcsICcyMDMuMC4xMTMuMC8yNCcsICcyMjQuMC4wLjAvNCcsICcyNDAuMC4wLjAvNCcpKQpFQ0hPX1VSTFMgPSAoJ2h0dHBzOi8vYXBpLmlwaWZ5Lm9yZycsICdodHRwczovL2NoZWNraXAuYW1hem9uYXdzLmNvbScpClZJUlRVQUxfS0lORFMgPSB7J2JyaWRnZScsICd2ZXRoJywgJ3R1bicsICd0YXAnLCAnd2lyZWd1YXJkJywgJ3Z4bGFuJywgJ2dyZScsICdncmV0YXAnLCAnZHVtbXknfQoKCmRlZiB0b29sX3BhdGgobmFtZSk6CiAgICAjIEFsc28gc3VwcG9ydCBkaXJlY3QgUHl0aG9uIGludm9jYXRpb24gZnJvbSBEZWJpYW4gbm9uLWxvZ2luIHNoZWxscy4KICAgIHJldHVybiBzaHV0aWwud2hpY2gobmFtZSwgcGF0aD1vcy5lbnZpcm9uLmdldCgnUEFUSCcsIG9zLmRlZnBhdGgpICsgJzovdXNyL3NiaW46L3NiaW4nKQoKCmRlZiBwdWJsaWNfaXB2NCh2YWx1ZSk6CiAgICB0cnk6CiAgICAgICAgYWRkcmVzcyA9IGlwYWRkcmVzcy5JUHY0QWRkcmVzcyh2YWx1ZSkKICAgIGV4Y2VwdCAoVmFsdWVFcnJvciwgVHlwZUVycm9yKToKICAgICAgICByZXR1cm4gRmFsc2UKICAgIHJldHVybiBub3QgYW55KGFkZHJlc3MgaW4gbmV0d29yayBmb3IgbmV0d29yayBpbiBFWENMVURFRCkKCgpkZWYgYWRkcmVzc2VzKGRvY3VtZW50LCBpbnRlcmZhY2VzPU5vbmUpOgogICAgaWYgbm90IGlzaW5zdGFuY2UoZG9jdW1lbnQsIGxpc3QpOgogICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoJ+e9keWNoeaJq+aPj+e7k+aenOagvOW8j+mUmeivr++8jOS4jeaJp+ihjOe8uuWkseWIpOaWrScpCiAgICByZXN1bHQgPSB7fQogICAgZm9yIGxpbmsgaW4gZG9jdW1lbnQ6CiAgICAgICAgbmFtZSA9IGxpbmtbJ2lmbmFtZSddCiAgICAgICAgaWYgaW50ZXJmYWNlcyBpcyBub3QgTm9uZSBhbmQgbmFtZSBub3QgaW4gaW50ZXJmYWNlczoKICAgICAgICAgICAgY29udGludWUKICAgICAgICBraW5kID0gbGluay5nZXQoJ2xpbmtpbmZvJywge30pLmdldCgnaW5mb19raW5kJykKICAgICAgICBpZiBraW5kIGluIFZJUlRVQUxfS0lORFMgb3IgbGluay5nZXQoJ2xpbmtfdHlwZScpID09ICdsb29wYmFjayc6CiAgICAgICAgICAgIGNvbnRpbnVlCiAgICAgICAgaWYgJ1VQJyBub3QgaW4gbGluay5nZXQoJ2ZsYWdzJywgW10pOgogICAgICAgICAgICBjb250aW51ZQogICAgICAgIGZvciBpdGVtIGluIGxpbmsuZ2V0KCdhZGRyX2luZm8nLCBbXSk6CiAgICAgICAgICAgIGlwID0gaXRlbS5nZXQoJ2xvY2FsJykKICAgICAgICAgICAgaWYgaXRlbS5nZXQoJ2ZhbWlseScpICE9ICdpbmV0JyBvciBpdGVtLmdldCgnc2NvcGUnKSAhPSAnZ2xvYmFsJyBvciBub3QgcHVibGljX2lwdjQoaXApOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgZmxhZ3MgPSBzZXQoaXRlbS5nZXQoJ2ZsYWdzJywgW10pKQogICAgICAgICAgICBpZiBmbGFncyAmIHsndGVudGF0aXZlJywgJ2RhZGZhaWxlZCcsICdkZXByZWNhdGVkJ30gb3IgYW55KGl0ZW0uZ2V0KGspIGZvciBrIGluICgndGVudGF0aXZlJywgJ2RhZGZhaWxlZCcsICdkZXByZWNhdGVkJykpOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgaWYgaXRlbS5nZXQoJ3ZhbGlkX2xpZmVfdGltZScpID09IDAgb3IgaXRlbS5nZXQoJ3ByZWZlcnJlZF9saWZlX3RpbWUnKSA9PSAwOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgaWYgaXAgaW4gcmVzdWx0IGFuZCByZXN1bHRbaXBdICE9IG5hbWU6CiAgICAgICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCflhaznvZHlnLDlnYDlh7rnjrDlnKjlpJrkuKrnvZHljaHvvIzpnIDlhYjmtojpmaTmrafkuYknKQogICAgICAgICAgICByZXN1bHRbaXBdID0gbmFtZQogICAgcmV0dXJuIHJlc3VsdAoKCmRlZiBzY2FuKGludGVyZmFjZXM9Tm9uZSk6CiAgICBwcm9jID0gc3VicHJvY2Vzcy5ydW4oW3Rvb2xfcGF0aCgnaXAnKSBvciAnaXAnLCAnLWonLCAnLWQnLCAnLTQnLCAnYWRkcicsICdzaG93J10sIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSwgdGltZW91dD0xNSkKICAgIGlmIHByb2MucmV0dXJuY29kZToKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+e9keWNoeaJq+aPj+Wksei0pe+8jOS/neeVmeWOn+eKtuaAgScpCiAgICByZXR1cm4gYWRkcmVzc2VzKGpzb24ubG9hZHMocHJvYy5zdGRvdXQpLCBpbnRlcmZhY2VzKQoKCmRlZiB2ZXJpZnlfZWdyZXNzKGlwKToKICAgIGlmIG5vdCBwdWJsaWNfaXB2NChpcCk6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcign5LuF5YWB6K645YWs572RIElQdjQnKQogICAgb2JzZXJ2YXRpb25zID0gW10KICAgIGZvciB1cmwgaW4gRUNIT19VUkxTOgogICAgICAgICMgRGlzYWJsZSBpbmhlcml0ZWQgcHJveHkgc2V0dGluZ3MgYW5kIGN1cmxyYzsgYmluZCBlYWNoIHNvdXJjZSBleHBsaWNpdGx5LgogICAgICAgIHRyeToKICAgICAgICAgICAgcHJvYyA9IHN1YnByb2Nlc3MucnVuKFt0b29sX3BhdGgoJ2N1cmwnKSBvciAnY3VybCcsICctcScsICctNCcsICctLXNpbGVudCcsICctLXNob3ctZXJyb3InLCAnLS1mYWlsJywKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICctLW5vcHJveHknLCAnKicsICctLXByb3RvJywgJz1odHRwcycsICctLW1heC10aW1lJywgJzgnLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgJy0tbWF4LWZpbGVzaXplJywgJzEyOCcsICctLWludGVyZmFjZScsIGlwLCB1cmxdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlLCB0aW1lb3V0PTEyKQogICAgICAgIGV4Y2VwdCAoc3VicHJvY2Vzcy5UaW1lb3V0RXhwaXJlZCwgVGltZW91dEVycm9yLCBPU0Vycm9yKToKICAgICAgICAgICAgb2JzZXJ2YXRpb25zLmFwcGVuZChOb25lKQogICAgICAgICAgICBjb250aW51ZQogICAgICAgIHZhbHVlID0gcHJvYy5zdGRvdXQuc3RyaXAoKQogICAgICAgIG9ic2VydmF0aW9ucy5hcHBlbmQodmFsdWUgaWYgcHJvYy5yZXR1cm5jb2RlID09IDAgYW5kIHB1YmxpY19pcHY0KHZhbHVlKSBlbHNlIE5vbmUpCiAgICBpZiBhbGwodmFsdWUgPT0gaXAgZm9yIHZhbHVlIGluIG9ic2VydmF0aW9ucyk6CiAgICAgICAgc3RhdHVzID0gJ3ZlcmlmaWVkJwogICAgZWxpZiBhbnkodmFsdWUgaXMgbm90IE5vbmUgYW5kIHZhbHVlICE9IGlwIGZvciB2YWx1ZSBpbiBvYnNlcnZhdGlvbnMpOgogICAgICAgIHN0YXR1cyA9ICdtaXNtYXRjaCcKICAgIGVsc2U6CiAgICAgICAgc3RhdHVzID0gJ3Vua25vd24nCiAgICByZXR1cm4geydzdGF0dXMnOiBzdGF0dXMsICdvYnNlcnZhdGlvbnMnOiBvYnNlcnZhdGlvbnN9CgoKZGVmIGluc3BlY3RfaXAoaXApOgogICAgdHJ5OgogICAgICAgIHJldHVybiB2ZXJpZnlfZWdyZXNzKGlwKQogICAgZXhjZXB0IChzdWJwcm9jZXNzLlRpbWVvdXRFeHBpcmVkLCBUaW1lb3V0RXJyb3IsIE9TRXJyb3IpOgogICAgICAgIHJldHVybiB7J3N0YXR1cyc6J3Vua25vd24nLCdvYnNlcnZhdGlvbnMnOltOb25lLE5vbmVdfQoKCmRlZiBtYWluKGFyZ3Y9Tm9uZSk6CiAgICBpbXBvcnQgYXJncGFyc2UKICAgIGltcG9ydCBjb25jdXJyZW50LmZ1dHVyZXMKICAgIGltcG9ydCBkYXRldGltZQogICAgcGFyc2VyPWFyZ3BhcnNlLkFyZ3VtZW50UGFyc2VyKGRlc2NyaXB0aW9uPSfml6fniYgv5paw54mI5pyN5Yqh5Zmo6YCa55So77ya5Y+q6K+75omr5o+P572R5Y2h5YWs572RIElQdjTvvIzlubbnu5Hlrprmr4/kuKrmupDlnLDlnYDpqozor4Hlh7rlj6PjgILkuI3kvJrlronoo4XoioLngrnjgIHmlLnnvZHnu5zjgIHlhpnlhaUgSVAg5rGg5oiW6YeN5ZCv5pyN5Yqh44CCJykKICAgIHBhcnNlci5hZGRfYXJndW1lbnQoJy0tanNvbicsYWN0aW9uPSdzdG9yZV90cnVlJyxoZWxwPSfovpPlh7ogSlNPTu+8jOaWueS+v+iEmuacrOiwg+eUqCcpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCctLWludGVyZmFjZScsYWN0aW9uPSdhcHBlbmQnLGhlbHA9J+S7heajgOafpeaMh+Wumue9keWNoe+8jOWPr+mHjeWkjeS8oOWFpScpCiAgICBwYXJzZXIuYWRkX2FyZ3VtZW50KCctLWlwJyxhY3Rpb249J2FwcGVuZCcsaGVscD0n5LuF5qOA5p+l5oyH5a6a55qE5bey57uR5a6a5YWs572RIElQ77yM5Y+v6YeN5aSN5Lyg5YWlJykKICAgIGFyZ3M9cGFyc2VyLnBhcnNlX2FyZ3MoYXJndikKICAgIG1pc3Npbmc9W3Rvb2wgZm9yIHRvb2wgaW4gKCdpcCcsJ2N1cmwnKSBpZiBub3QgdG9vbF9wYXRoKHRvb2wpXQogICAgaWYgbWlzc2luZzoKICAgICAgICByYWlzZSBSdW50aW1lRXJyb3IoJ+e8uuWwkeWRveS7pO+8micrJywgJy5qb2luKG1pc3NpbmcpKyfvvJtVYnVudHUgMjAuMDQgLyBEZWJpYW4gMTEg6K+35YWI5LulIHJvb3Qg6L+Q6KGM77yaYXB0LWdldCB1cGRhdGUgJiYgYXB0LWdldCBpbnN0YWxsIC15IHB5dGhvbjMgaXByb3V0ZTIgY3VybCBjYS1jZXJ0aWZpY2F0ZXMnKQogICAgZm91bmQ9c2NhbihhcmdzLmludGVyZmFjZSkKICAgIGlmIGFyZ3MuaXA6CiAgICAgICAgcmVxdWVzdGVkPXNldChhcmdzLmlwKQogICAgICAgIGlmIG5vdCByZXF1ZXN0ZWQuaXNzdWJzZXQoZm91bmQpOgogICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCfmjIflrprlnLDlnYDkuI3mmK/miYDpgInnvZHljaHkuIrlt7LlkK/nlKjnmoTlhaznvZEgSVB2NO+8micrJywgJy5qb2luKHNvcnRlZChyZXF1ZXN0ZWQtc2V0KGZvdW5kKSkpKQogICAgICAgIGZvdW5kPXtpcDppbnRlcmZhY2UgZm9yIGlwLGludGVyZmFjZSBpbiBmb3VuZC5pdGVtcygpIGlmIGlwIGluIHJlcXVlc3RlZH0KICAgIGlmIGxlbihmb3VuZCk+NjQ6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcign5Y+R546w6LaF6L+HIDY0IOS4quWAmemAieWcsOWdgO+8jOivt+eUqCAtLWludGVyZmFjZSDmiJYgLS1pcCDpmZDlrprojIPlm7QnKQogICAgd2l0aCBjb25jdXJyZW50LmZ1dHVyZXMuVGhyZWFkUG9vbEV4ZWN1dG9yKG1heF93b3JrZXJzPTQpIGFzIGV4ZWN1dG9yOgogICAgICAgIHJlc3VsdHM9bGlzdChleGVjdXRvci5tYXAoaW5zcGVjdF9pcCxmb3VuZCkpCiAgICByb3dzPVtkaWN0KGlwPWlwLGludGVyZmFjZT1pbnRlcmZhY2UsKipyZXN1bHQpIGZvciAoaXAsaW50ZXJmYWNlKSxyZXN1bHQgaW4gemlwKGZvdW5kLml0ZW1zKCkscmVzdWx0cyldCiAgICByZXBvcnQ9eydzY2hlbWEnOjEsJ2F0JzpkYXRldGltZS5kYXRldGltZS5ub3coZGF0ZXRpbWUudGltZXpvbmUudXRjKS5pc29mb3JtYXQoKSwKICAgICAgICAgICAgJ3JlYWRfb25seSc6VHJ1ZSwnZmFtaWx5JzonaXB2NCcsJ2VjaG9fc291cmNlcyc6bGlzdChFQ0hPX1VSTFMpLCdhZGRyZXNzZXMnOnJvd3MsCiAgICAgICAgICAgICd2ZXJpZmllZF9jb3VudCc6c3VtKHJbJ3N0YXR1cyddPT0ndmVyaWZpZWQnIGZvciByIGluIHJvd3MpfQogICAgaWYgYXJncy5qc29uOgogICAgICAgIHByaW50KGpzb24uZHVtcHMocmVwb3J0LGVuc3VyZV9hc2NpaT1GYWxzZSxpbmRlbnQ9MikpCiAgICBlbHNlOgogICAgICAgIHByaW50KCflhaznvZEgSVB2NCDmiavmj4/vvIjlj6ror7vvvIzkuI3kv67mlLnoioLngrnmiJbnvZHnu5zvvIknKQogICAgICAgIHByaW50KCdJUCAgICAgICAgICAgICAgICDnvZHljaEgICAgICAgICAg5Ye65Y+j6aqM6K+BICAgICAgICAg5qOA5rWL56uZ6L+U5ZueJykKICAgICAgICBsYWJlbHM9eyd2ZXJpZmllZCc6J+mAmui/hycsJ21pc21hdGNoJzon5LiN5LiA6Ie0L05BVCcsJ3Vua25vd24nOifmnKrnoa7orqQv6LaF5pe2J30KICAgICAgICBmb3Igcm93IGluIHJvd3M6CiAgICAgICAgICAgIHZhbHVlcz0nLCAnLmpvaW4odiBvciAn5peg5pyJ5pWI5ZON5bqUJyBmb3IgdiBpbiByb3dbJ29ic2VydmF0aW9ucyddKQogICAgICAgICAgICBwcmludCgnJS0xN3MgJS0xM3MgJS0xMnMgJXMnJShyb3dbJ2lwJ10scm93WydpbnRlcmZhY2UnXSxsYWJlbHNbcm93WydzdGF0dXMnXV0sdmFsdWVzKSkKICAgICAgICBpZiBub3Qgcm93czpwcmludCgn5rKh5pyJ5Y+R546w56ym5ZCI5p2h5Lu255qE572R5Y2h5YWs572RIElQdjTjgILmjqfliLblj7Dlt7LliIbphY3kvYbmnKrnu5HlrprliLDnvZHljaHnmoTlnLDlnYDkuI3kvJrliJflh7rjgIInKQogICAgICAgIHByaW50KCflh7rlj6Ppqozor4HkuI3ku6PooajlpJbpg6jnlKjmiLfog73ov57mjqUgVlBO77yM5Lmf5LiN5Lya6Ieq5Yqo5bu66IqC54K55oiW5o2iIElQ44CCJykKICAgIHJldHVybiA0IGlmIG5vdCByb3dzIGVsc2UgMCBpZiBhbGwoclsnc3RhdHVzJ109PSd2ZXJpZmllZCcgZm9yIHIgaW4gcm93cykgZWxzZSAzCgoKaWYgX19uYW1lX189PSdfX21haW5fXyc6CiAgICBpbXBvcnQgc3lzCiAgICB0cnk6c3lzLmV4aXQobWFpbigpKQogICAgZXhjZXB0IChFeGNlcHRpb24sS2V5Ym9hcmRJbnRlcnJ1cHQpIGFzIGVycm9yOgogICAgICAgIHByaW50KCfmiavmj4/mnKrlrozmiJDvvJonKyhzdHIoZXJyb3IpIGlmIGlzaW5zdGFuY2UoZXJyb3IsKFJ1bnRpbWVFcnJvcixWYWx1ZUVycm9yKSkgZWxzZSB0eXBlKGVycm9yKS5fX25hbWVfXyksZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHN5cy5leGl0KDIpCg=='}.items():
        _pathlib.Path(_bundle.name, _name).write_bytes(_base64.b64decode(_data))
    _sys.path.insert(0, _bundle.name)
"""WhaleNode 服务器本机安装器，仅依赖 Python 标准库。"""
import argparse
from collections import Counter
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
from ephemeral_ports import configure as configure_ephemeral_ports

ROOT = Path('/var/lib/whalenode-installer')
CONF = Path('/etc/whalenode')
UNIT = Path('/etc/systemd/system/whalenode.service')
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
    mode.add_argument('--retune', action='store_true', help='升级 CPU/内存后执行：按当前配置重算后端 CPU/内存上限与内核参数，修正网卡队列算法（上限变化时重启后端数秒）')
    mode.add_argument('--hide', action='store_true', help='面板隐藏本机节点（用户不再收到）')
    mode.add_argument('--show', action='store_true', help='面板重新显示本机节点')
    mode.add_argument('--uninstall', action='store_true', help='隐藏并删除面板节点，卸载本机服务和监控')
    p.add_argument('--yes', action='store_true', help='卸载时不再确认')
    # BooleanOptionalAction was introduced in Python 3.9 (Ubuntu 20.04 has 3.8).
    p.add_argument('--publish', action='store_true', default=None,
                   help='安装后直接在面板显示（默认开启；--no-publish 保持隐藏）')
    p.add_argument('--no-publish', dest='publish', action='store_false', default=None,
                   help='安装后保持面板隐藏')
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

# 历史机队池 + 现有 finder 新筛选结果；来源和测量范围见 sni-pool-provenance.json。
SNI_POOL=(
    'www.intel.com',
    'www.lg.com',
    'www.python.org',
    'www.qualcomm.com',
    'www.samsung.com',
    'www.postgresql.org',
    'www.kernel.org',
    'www.tesla.com',
    'www.sony.com',
    'www.speedtest.net',
    'www.cisco.com',
    'www.oracle.com',
    'www.ibm.com',
    'www.dell.com',
    'www.asus.com',
    'www.siemens.com',
    'www.philips.com',
    'www.canon.com',
    'www.epson.com',
    'www.nokia.com',
    'www.sap.com',
    'www.xerox.com',
    'www.fujitsu.com',
    'www.debian.org',
    'www.redhat.com',
    'www.jetbrains.com',
    'www.lenovo.com',
    'www.bosch.com',
    'www.panasonic.com',
    'www.toshiba.com',
    'www.logitech.com',
    'www.autodesk.com',
    'www.adobe.com',
    'www.atlassian.com',
    'www.spotify.com',
    'www.booking.com',
    'www.abb.com',
    'www.schneider-electric.com',
    'www.bmw.com',
    'www.volkswagen.com',
    'www.shell.com',
    'www.airbus.com',
    'www.ricoh.com',
    'www.brother.com',
    'www.zeiss.com',
    'www.bayer.com',
    'www.basf.com',
    'www.nxp.com',
    'www.infineon.com',
    'www.st.com',
    'www.arm.com',
    'www.micron.com',
    'www.juniper.net',
    'www.arista.com',
    'www.netapp.com',
    'www.citrix.com',
    'www.apache.org',
    'www.php.net',
    'www.rust-lang.org',
    'www.thalesgroup.com',
    'www.continental.com',
    'www.olympus-global.com',
    'www.yamaha.com',
    'www.denso.com',
    'linkedin.com',
    'googletagmanager.com',
    'netflix.com',
    'wordpress.org',
    'goo.gl',
    'nic.ru',
    'wordpress.com',
    'vk.com',
    'apache.org',
    'app-measurement.com',
    'googleadservices.com',
    'app-analytics-services.com',
    'prodregistryv2.org',
    'dns.google',
    'forms.gle',
    'gravatar.com',
    'archive.org',
    'mailinabox.email',
    'pki.goog',
    'telegram.org',
    'deere.com',
    'dnsmadeeasy.com',
    'launchdarkly.com',
    'vk.ru',
    'issuu.com',
    'crpt.ru',
    'yandex.com',
    'ngenix.net',
    'vkontakte.ru',
    'cnbc.com',
    'duckduckgo.com',
    'mikrotik.com',
    'featureassets.org',
    'eye4.cn',
    'arxiv.org',
    'beyondwickedmapping.org',
    'run.app',
    'openx.net',
    'time.com',
    'techcrunch.com',
    'share.google',
    'elpais.com',
    'g.co',
    'quantserve.com',
    'id5-sync.com',
    'creativecdn.com',
    'asus.com',
    'bandcamp.com',
    'shopee.co.id',
    'adform.net',
    'ipinfo.io',
    'shopee.com.br',
    'daum.net',
    'allegro.pl',
    'myspace.com',
    'onetag-sys.com',
    'fbsbx.com',
    'eu-1-id5-sync.com',
    'px-cloud.net',
    'tsyndicate.com',
    'tailscale.com',
    'sofascore.com',
    'docomo.ne.jp',
    'nypost.com',
    'app-analytics-services-att.com',
    'as.com',
    'magnific.com',
    'adblockplus.org',
    'lwsdns.com',
    'yandex.kz',
    'yandex.com.tr',
    'fb.me',
    'cspserver.net',
    'xhamster19.com',
    'xhamster2.com',
    'vnexpress.net',
    'safety.google',
    'xhaccess.com',
    'b7510.com',
    'lichess.org',
    'xhopen.com',
    'xhname.com',
    'sapo.pt',
    'divar.ir',
    'kernel.org',
    'labs.google',
    'tapad.com',
    'justdial.com',
    'shopee.com.my',
    'edna.ru',
    'thisvid.com',
    'xhspot.com',
    'hitomi.la',
    'xhsocial.com',
    'rule34video.com',
    'mangabuff.ru',
    'simpcity.cr',
    'parklogic.com',
    'ekstrabladet.dk',
    '1c.ru',
    'jcphi.com',
    'akismet.com',
    'thexh.live',
    'pornoborshch.com',
    'fedoraproject.org',
    '6opo.com',
    'contextweb.com',
    'mechacomic.jp',
    's8ey.com',
    'sinoptik.ua',
    'rkv1.com',
    'ak2yy.com',
    'nickfinder.com',
    'site.com',
    'imgsrc.ru',
    'blackrussia.online',
    'anses.gob.ar',
    '33apk.com',
    'hotxv.com',
    'packzy.com',
    'vnsextop1.com',
    'xxxvideosind.com',
    'staseraintv.com',
    'your-server.de',
    'kkstories.com',
    'dantri.com.vn',
    'magnit.ru',
    'hh.ru',
    'mercadolibre.com',
    'badoo.com',
    'firstvds.ru',
    'jino.ru',
    'ns1p.net',
    'fb.watch',
    'fullxh.com',
    'npci.org.in',
    'yimg.com',
    'gama.ir',
    'limo.media',
    '99rdd.com',
    'atcpulsa.store',
)

def validate_sni_pool(doc, max_age=7*86400):
    if not isinstance(doc,dict) or doc.get('schema')!=1:raise ValueError('SNI 清单格式无效')
    stamp=doc.get('generated_at')
    if isinstance(stamp,bool) or not isinstance(stamp,(int,float)) or not 0 <= time.time()-stamp <= max_age:
        raise ValueError('SNI 清单过期或时间无效')
    names=doc.get('domains')
    if not isinstance(names,list) or not 1 <= len(names) <= 4096:raise ValueError('SNI 候选数量无效')
    for name in names:
        if not isinstance(name,str) or len(name)>253 or '.' not in name or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',label) for label in name.split('.')):
            raise ValueError('SNI 候选域名无效')
    return list(dict.fromkeys(names))


def load_sni_pool(args,state):
    # Stable data endpoint next to the manifest. Never follows redirects or sends
    # download credentials to a different origin; no remote code is executed.
    release=state.get('release_manifest')
    if not release:
        print('未配置发布清单，使用内置 SNI 应急候选；仍需本机 TLS 验证',flush=True)
        return list(SNI_POOL)
    url=urllib.parse.urljoin(release,'sni-pool.json')
    cache=ROOT/'sni-pool-cache.json'
    previous=None
    try:
        saved=json.loads(cache.read_text())
        if saved.get('source')==url:
            validate_sni_pool(saved['pool']);previous=saved['pool']
    except (OSError,ValueError,KeyError,TypeError):pass
    try:
        auth=download_auth(args,url,release)
        doc=request(url,auth) if auth else request(url)
        names=validate_sni_pool(doc)
        if previous and doc['generated_at'] < previous['generated_at']:
            raise ValueError('SNI 清单版本倒退')
        atomic(cache,json.dumps({'source':url,'pool':doc}))
        print('SNI 实时清单：'+str(len(names))+' 个候选，更新于 '+time.strftime('%Y-%m-%d %H:%M:%S UTC',time.gmtime(doc['generated_at'])),flush=True)
        return names
    except (RuntimeError,ValueError,OSError,TypeError):
        if previous:
            print('SNI 在线更新失败，使用最近有效缓存；仍需本机 TLS 验证',flush=True)
            return validate_sni_pool(previous)
        print('SNI 在线更新失败且无有效缓存，使用内置应急候选；仍需本机 TLS 验证',flush=True)
        return list(SNI_POOL)


def sni_usage(nodes):
    counts=Counter()
    for node in nodes:
        tls=node.get('tls_settings')
        names={node.get('server_name'),tls.get('server_name') if isinstance(tls,dict) else None}
        # The same domain in both fields of one row counts once; hidden rows count too.
        counts.update({name.lower().rstrip('.') for name in names if isinstance(name,str) and name})
    return counts


def choose_sni(used,tls13=False,pool=None):
    counts=Counter(used)
    # Shuffle ties, then prefer unused / least-used domains. Reuse still requires TLS.
    pool=SNI_POOL if pool is None else pool
    candidates=secrets.SystemRandom().sample(pool,len(pool))
    candidates.sort(key=lambda host:counts[host])
    failures=Counter()
    for host in candidates:
        try:
            with socket.create_connection((host,443),timeout=5) as sock:
                with ssl.create_default_context().wrap_socket(sock,server_hostname=host) as tls:
                    version=tls.version()
                    if not version or (tls13 and version!='TLSv1.3'):
                        failures['TLS版本不满足要求']+=1
                        continue
                    if counts[host]:
                        print('自动 SNI 复用：'+host+'（面板/本次已使用 '+str(counts[host])+' 次，TLS 验证通过）',flush=True)
                    return host
        except ssl.SSLCertVerificationError:failures['证书验证失败']+=1
        except ssl.SSLError:failures['TLS握手失败']+=1
        except OSError:failures['DNS/连接失败']+=1
    detail='、'.join(k+'='+str(v) for k,v in failures.items())
    raise RuntimeError('自动 SNI 测试没有通过（已测试 '+str(len(candidates))+' 个候选，允许复用；'+detail+'），请检查网络/系统时间/CA，或通过 --sni 指定已验证域名')

def dependency_check():
    if not Path('/run/systemd/system').is_dir():raise RuntimeError('需要使用 systemd 的服务器')
    needed=('nft','ss','tc','sysctl','modprobe','useradd','runuser')
    if all(shutil.which(x) for x in needed):return
    print('正在安装缺少的运行依赖…',flush=True)
    if shutil.which('apt-get'):
        run('apt-get','update','-qq')
        run('env','DEBIAN_FRONTEND=noninteractive','apt-get','install','-y','--no-install-recommends','nftables','iproute2','procps','kmod','passwd','util-linux','ca-certificates')
    elif shutil.which('dnf'):
        run('dnf','install','-y','nftables','iproute','procps-ng','kmod','shadow-utils','util-linux','ca-certificates')
    else:raise RuntimeError('无法安装依赖：未找到 apt-get 或 dnf')

def has_additional_ip_instances():
    path=ROOT/'ip-pool.json'
    if path.exists():
        data=json.loads(path.read_text())
        if any(e.get('unit') or e.get('slot') for e in data.get('addresses',{}).values()):return True
    return any(p.name!='whalenode-ip-pool.service' for p in Path('/etc/systemd/system').glob('whalenode-ip-*.service'))


def rollback(state):
    if has_additional_ip_instances():raise RuntimeError('存在附加 IP 实例，不能回滚共用出口规则或原服务；请先逐实例处理')
    if not state.get('owns_service') and not state.get('owns_egress'):raise RuntimeError('本任务尚未修改服务或系统参数，无需回滚')
    run('systemctl','disable','--now','whalenode.service',check=False)
    run('systemctl','disable','--now','whalenode-egress.service',check=False)
    if state.get('owns_egress'):run('nft','delete','table','inet','whalenode_egress',check=False)
    restore_source_ports(state)
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

def tune_source_ports(state, protocols):
    reserved=','.join(str(PROTOCOLS[p][1]) for p in protocols)
    receipt=configure_ephemeral_ports(reserved,apply=True)
    if not receipt.get('applied') or receipt.get('new_range')!='1024 65535':
        raise RuntimeError('临时端口配置未通过校验，停止安装')
    state.setdefault('ephemeral_port_backups',[]).append(receipt['backup'])
    state['ephemeral_ports']=receipt
    atomic(ROOT/'state.json',json.dumps(state,ensure_ascii=False,indent=2))
    print('临时端口范围 1024–65535，保留业务端口后可用 '+str(receipt['capacity']),flush=True)


def restore_source_ports(state):
    for backup in reversed(state.get('ephemeral_port_backups',[])):
        path=Path(backup)
        if path.parent!=Path('/root') or not path.name.startswith('whale-ephemeral-max-'):
            raise RuntimeError('临时端口备份路径不正确，停止恢复')
        run('python3',str(path/'rollback.py'))
    state['ephemeral_port_backups']=[]


def tune_kernel(facts):
    """Conservative, resource-bounded settings; never rewrite driver IRQ or offload blindly.

    The queueing discipline must be fq_codel, not fq: a sing hysteria2 inbound is a single UDP
    socket, and fq treats a socket as one flow with a 100-packet flow_limit, so under load it
    dropped the machine's entire HY2 traffic (fleet finding 2026-09-16; v0.3.4 and earlier set fq).
    Returns the default-route device and its qdisc after the change."""
    settings={'net.core.somaxconn':8192,'net.core.rmem_max':facts['socket_buffer'],'net.core.wmem_max':facts['socket_buffer'],'net.ipv4.tcp_mtu_probing':1,'net.core.default_qdisc':'fq_codel'}
    old=json.loads((ROOT/'sysctl-before.json').read_text()) if (ROOT/'sysctl-before.json').exists() else {}
    for k in settings:
        if k not in old: old[k]=run('sysctl','-n',k).stdout.strip()
    run('modprobe','tcp_bbr',check=False)
    if 'bbr' in run('sysctl','-n','net.ipv4.tcp_available_congestion_control').stdout.split():
        if 'net.ipv4.tcp_congestion_control' not in old:old['net.ipv4.tcp_congestion_control']=run('sysctl','-n','net.ipv4.tcp_congestion_control').stdout.strip()
        settings['net.ipv4.tcp_congestion_control']='bbr'
    atomic(ROOT/'sysctl-before.json',json.dumps(old))
    atomic('/etc/sysctl.d/90-whalenode.conf',''.join(str(k)+'='+str(v)+'\n' for k,v in settings.items()),0o644)
    run('sysctl','-p','/etc/sysctl.d/90-whalenode.conf')
    # default_qdisc only applies to qdiscs created later. Replace an fq root (or the fq children of
    # an mq root) on the default-route device now; any other discipline someone chose is left alone.
    route=run('ip','-4','route','show','default',check=False).stdout.split()
    dev=route[route.index('dev')+1] if 'dev' in route[:-1] else ''
    if not dev or not shutil.which('tc'):return dev,''
    shown=run('tc','qdisc','show','dev',dev,check=False).stdout
    if re.search(r'^qdisc fq ',shown,re.M):
        if shown.startswith('qdisc mq'):run('tc','qdisc','replace','dev',dev,'root','handle','1:','mq',check=False)
        else:run('tc','qdisc','replace','dev',dev,'root','fq_codel',check=False)
        shown=run('tc','qdisc','show','dev',dev,check=False).stdout
    return dev,shown

def wait_listening(selected):
    missing=selected[:]
    for _ in range(36):
        missing=[]
        for proto in selected:
            sock='-lun' if proto=='hy2' else '-ltn'
            if len(run('ss',sock,'sport = :'+str(PROTOCOLS[proto][1])).stdout.splitlines())<2:missing.append(proto)
        if not missing:break
        time.sleep(5)
    return missing

def retune(state):
    """After a CPU/memory upgrade: GOMAXPROCS, GOMEMLIMIT and socket buffers were fixed at install time,
    so an upgraded machine kept using the old core count. Recompute from the current machine, fix the
    qdisc, and restart the backend only if its limits changed."""
    if state.get('phase') not in ('installed','published') or not state.get('owns_service'):
        raise RuntimeError('本机没有由本安装器装好的 WhaleNode，无需 --retune')
    facts=resources()
    tune_source_ports(state,state.get('protocols') or [])
    dev,shown=tune_kernel(facts)
    unit=UNIT
    text=unit.read_text()
    new=re.sub(r'GOMEMLIMIT=\d+MiB','GOMEMLIMIT='+str(facts['go_memory_mib'])+'MiB',text)
    new=re.sub(r'GOMAXPROCS=\d+','GOMAXPROCS='+str(facts['cpus']),new)
    before=state.get('resources') or {}
    if new!=text:
        atomic(unit,new,0o644)
        run('systemctl','daemon-reload')
        print('后端 CPU/内存上限已变化，重启 whalenode（连接会断开几秒）…',flush=True)
        run('systemctl','restart','whalenode.service')
        missing=wait_listening(state.get('protocols') or [])
        if missing:raise RuntimeError('重启后监听未就绪，协议：'+','.join(missing)+'；使用 journalctl -u whalenode 检查')
        verify_service(state)
    state['resources']=facts;save_state(state)
    qd=' '.join(sorted(set(re.findall(r'^qdisc (\S+)',shown,re.M)))) or '未知'
    print('已按当前配置调整：CPU %s→%s 核，内存上限 %s→%s MiB，套接字缓冲 %s 字节，网卡 %s 队列算法 %s%s'%(
        before.get('cpus','?'),facts['cpus'],before.get('go_memory_mib','?'),facts['go_memory_mib'],facts['socket_buffer'],
        dev or '?',qd,'' if new!=text else '（后端上限未变，未重启）'))


def rows(response):
    data = response.get('data')
    if not isinstance(data, list): raise RuntimeError('V2Board getNodes 响应格式不兼容')
    return data

# 线路名称不准带 IP（owner 2026-11-07）：点分或横线分隔的 IPv4 都算。
NAME_IP=re.compile(r'\d{1,3}([.-])\d{1,3}\1\d{1,3}\1\d{1,3}')

def settle_name(state,all_nodes):
    """本机线路名称的前缀（协议名之前那段）。
    已有本任务的面板行 → 以面板为准（后台可能已改名）；否则自动命名 = 地区 + 两位编号，
    编号取面板里同地区还没人用的最小值。旧版装机留下的带 IP 名称在这里去掉 IP 重新编号。"""
    own=[str(x.get('name') or '') for x in all_nodes if state.get('nonce') in (x.get('tags') or [])]
    own=[n.split(' · ')[0] for n in own if ' · ' in n and not NAME_IP.search(n)]
    if own: return own[0]
    name=state['name']
    if NAME_IP.search(name):
        name=re.sub(r'[\s._-]+$','',re.sub(r'\s+',' ',NAME_IP.sub('',name))).strip();state['name_auto']=True
    if not state.get('name_auto') or re.search(r' \d{2}$',name): return name
    used={str(x.get('name') or '') for x in all_nodes}
    n=1
    while any(u.startswith('%s %02d · '%(name,n)) for u in used): n+=1
    return '%s %02d'%(name,n)
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
    if has_additional_ip_instances():raise RuntimeError('存在附加 IP 实例，不能删除共用核心、配置和监控；请先逐实例处理')
    if not state.get('ids') and not state.get('owns_service'):raise RuntimeError('本机没有安装器任务，无需卸载')
    if not args.yes:
        if args.non_interactive:raise ValueError('非交互卸载需要 --yes 确认')
        if prompt('将隐藏并删除面板节点、卸载 WhaleNode 和监控。输入 yes 确认')!='yes':
            print('已取消，未做任何修改。');return
    admin=admin_token(args) if state.get('ids') else None
    if admin and state.get('published'):
        set_show(state,admin,0);print('面板已隐藏。',flush=True)
    if Path('/etc/systemd/system/whalenode-ip-pool.timer').exists():
        run('systemctl','disable','--now','whalenode-ip-pool.timer',check=False)
        run('systemctl','stop','whalenode-ip-pool.service',check=False)
        for name in ('whalenode-ip-pool.timer','whalenode-ip-pool.service'):
            (Path('/etc/systemd/system')/name).unlink(missing_ok=True)
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
    restore_source_ports(state)
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

def resume_group(requested,state,nodes=None):
    existing=state.get('node_group')
    if state.get('ids') and not existing:
        if nodes is None:return None
        identities={(PROTOCOLS[p][0],int(nid)) for p,nid in state['ids'].items()}
        groups=set()
        for row in nodes:
            if (row.get('type'),int(row.get('id',0))) not in identities:continue
            if row.get('host')!=state.get('host') or state.get('nonce') not in (row.get('tags') or []):
                raise RuntimeError('旧节点身份核对失败，未修改分组或服务')
            groups.update(tag[9:] for tag in (row.get('tags') or []) if isinstance(tag,str) and tag.startswith('wn-group:'))
        if len(groups)!=1:raise RuntimeError('无法唯一恢复原节点分组，未修改服务；请核对旧节点 wn-group 标签')
        existing=groups.pop()
        print('已从旧节点标签恢复分组：'+existing,flush=True)
    chosen=existing if state.get('ids') else requested or existing or 'legacy_all'
    if not isinstance(chosen,str) or not re.fullmatch('[a-z0-9_]{1,48}',chosen):raise ValueError('网关节点分组格式无效')
    if state.get('ids') and requested and requested!=chosen:
        print('追加/续跑沿用原分组 '+chosen+'；忽略命令中的 --node-group '+requested+'，不迁移已有节点',flush=True)
    return chosen


def backend_preflight(state):
    for service in ('V2bX.service','whalenode.service'):
        if run('systemctl','is-active','--quiet',service,check=False).returncode:continue
        if service!='whalenode.service' or not state.get('owns_service'):
            raise RuntimeError('发现已有后端服务，未覆盖：'+service)
        pid=run('systemctl','show','-p','MainPID','--value',service).stdout.strip()
        if not pid.isdigit() or int(pid)<=0:raise RuntimeError('无法确认已有后端进程，未停止服务')
        if hashlib.sha256(Path('/proc/'+pid+'/exe').read_bytes()).hexdigest()!=state.get('binary_sha256'):
            raise RuntimeError('已有后端哈希与安装记录不一致，未停止服务')
        return pid
    return None


def check_install_ports(selected,pid):
    for proto in selected:
        sock='-Hlunp' if proto=='hy2' else '-Hltnp'
        lines=run('ss',sock,'sport = :'+str(PROTOCOLS[proto][1])).stdout.splitlines()
        for line in lines:
            owners=set(re.findall(r'pid=(\d+)',line))
            if not pid or owners!={pid}:
                raise RuntimeError('所需端口被其他进程占用，协议：'+proto+'；未停止已有服务')


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
    if args.retune:
        retune(state);return
    if args.hide or args.show or args.uninstall:
        manage(args,state);return
    def wanted(value):
        return list(dict.fromkeys(x.strip().lower() for x in value.split(',') if x.strip()))
    added=[x for x in wanted(args.protocols) if x not in state.get('protocols',[])] if args.protocols and state.get('protocols') else []
    if added and state.get('phase') in ('installed','published'):
        # 追加协议：已有面板行保留，只为新增协议建行，重写配置、重启后端，再显示全部线路。
        print('追加协议：'+','.join(added)+'（已有 '+','.join(state['protocols'])+' 保留）',flush=True)
        state['publish']=state.get('publish',True) if args.publish is None else args.publish
        state['published']=False  # Persist only after preflight validation begins.
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
    running_pid=backend_preflight(state)
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
        if not state.get('name'):
            # 线路名称不准带 IP（owner 2026-11-07）。先记地区，编号等拿到面板清单后再定。
            state['name'] = str(geo['country_code']) + ' ' + str(geo['city']); state['name_auto'] = True
    state['host'] = str(ipaddress.IPv4Address(state['host']))
    if not state.get('name'):
        geo = ipv4_request('https://ipwho.is/' + state['host'])
        if geo.get('success') is not True: raise RuntimeError('地区识别失败，请提供 --name')
        state['name'] = str(geo['country_code']) + ' ' + str(geo['city']); state['name_auto'] = True
    if NAME_IP.search(state['name']) and not state.get('ids'):
        raise ValueError('节点名称不能包含 IP 地址：'+state['name'])
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
    state['node_group']=resume_group(args.node_group,state)
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
    # Owned listeners remain online during preflight; foreign owners still fail.
    check_install_ports(selected,running_pid)
    all_nodes = rows(request(state['admin_url']+'/server/manage/getNodes',admin))
    state['name']=settle_name(state,all_nodes);save('preflight')
    if not state.get('node_group'):
        state['node_group']=resume_group(args.node_group,state,all_nodes)
        save('preflight')
    state.setdefault('snis',{})
    used=sni_usage(all_nodes)
    pool=load_sni_pool(args,state) if not state.get('sni') and any(p not in state['snis'] for p in selected) else []
    for proto in selected:
        if proto not in state['snis']:
            state['snis'][proto]=state.get('sni') or choose_sni(used,tls13=proto=='vless',pool=pool)
            used[state['snis'][proto].lower().rstrip('.')]+=1;save('preflight')
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
    exists=run('nft','list','table','inet','whalenode_egress',check=False).returncode==0
    if exists and not state.get('owns_egress'):
        raise RuntimeError('发现非本任务的出口规则表，请先检查')
    if run('id','-u','whalenode',check=False).returncode:
        run('useradd','--system','--home-dir',str(CONF),'--shell','/usr/sbin/nologin','whalenode')
    uid=int(run('id','-u','whalenode').stdout)
    CONF.mkdir(mode=0o700,parents=True,exist_ok=True)
    nodes=[]
    for proto in selected:
        typ='hysteria2' if proto=='hy2' else proto
        nodes.append({'Core':'sing','ApiHost':state['api_url'],'ApiKey':api_key,'NodeID':state['ids'][proto],'NodeType':typ,'Timeout':180,'ListenIP':'0.0.0.0','SendIP':'0.0.0.0','CertConfig':{'CertMode':'self','CertDomain':state['snis'][proto],'CertFile':str(CONF/(proto+'.cer')),'KeyFile':str(CONF/(proto+'.key'))}})
    config={'Log':{'Level':'warn','Output':''},'Cores':[{'Type':'sing','Log':{'Level':'warn'},'OriginalPath':str(CONF/'sing_original.json')}],'Nodes':nodes}
    # Only stop once all network/download/panel preflight has succeeded.
    check_install_ports(selected,running_pid)
    if state.get('owns_service'):
        run('systemctl','stop','whalenode.service')
    atomic(CONF/'config.json',json.dumps(config))
    atomic(CONF/'sing_original.json',json.dumps({'route':{'rules':[]}}))
    run('chown','-R','whalenode:whalenode',str(CONF));CONF.chmod(0o700)
    # Own only this table. IPv6 management and other services are unaffected.
    table='table inet whalenode_egress {\n chain output {\n  type filter hook output priority 0; policy accept;\n  meta skuid '+str(uid)+' meta nfproto ipv6 counter reject\n }\n}\n'
    nft=Path('/etc/whalenode-egress.nft')
    atomic(nft,table)
    if not exists:
        run('nft','--check','-f',str(nft))
        state['owns_egress']=True;save('egress')
        run('nft','-f',str(nft))
    atomic('/etc/systemd/system/whalenode-egress.service','[Unit]\nBefore=whalenode.service\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/sbin/nft -f /etc/whalenode-egress.nft\nExecStop=/usr/sbin/nft delete table inet whalenode_egress\n[Install]\nWantedBy=multi-user.target\n',0o644)
    tune_source_ports(state,selected)
    tune_kernel(facts)
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
    missing=wait_listening(selected)
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
    try:
        if not sys.argv[1:] or '--menu' in sys.argv[1:]:
            import node_menu
            node_menu.main([arg for arg in sys.argv[1:] if arg!='--menu'])
        elif sys.argv[1:2]==['--ip-pool']:
            import ip_pool_cli
            ip_pool_cli.main(sys.argv[2:])
        else:main()
    except (Exception,KeyboardInterrupt) as e:
        # Do not emit exception URLs, request bodies, credentials or stack locals.
        print('操作未完成：'+(str(e) if isinstance(e,(RuntimeError,ValueError)) else type(e).__name__),file=sys.stderr)
        sys.exit(1)

WHALE_INSTALLER_PY
