"""Generate the single-file shell entry; no dependencies or compilation."""
from pathlib import Path
import base64
import json
root=Path(__file__).resolve().parent
prefix='''#!/usr/bin/env bash
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
    sed -e 's#://deb.debian.org/debian-security#://archive.debian.org/debian-security#g' \\
        -e 's#://security.debian.org/debian-security#://archive.debian.org/debian-security#g' \\
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
'''
ports=(root/'ephemeral_ports.py').read_text(encoding='utf-8')
embedded='import sys,types\n_ep=types.ModuleType("ephemeral_ports")\nexec('+repr(ports)+',_ep.__dict__)\nsys.modules["ephemeral_ports"]=_ep\n'
files={name:base64.b64encode((root/name).read_bytes()).decode() for name in
       ('installer.py','ephemeral_ports.py','ip_pool.py','ip_pool_cli.py','ip_pool_transaction.py','node_menu.py','scan_public_ips.py')}
loader='''# Embedded IP management modules are unpacked only for the IP-pool command.
import sys as _sys
if not _sys.argv[1:] or '--menu' in _sys.argv[1:] or _sys.argv[1:2] == ['--ip-pool']:
    import tempfile as _tempfile, pathlib as _pathlib, base64 as _base64, atexit as _atexit
    _bundle = _tempfile.TemporaryDirectory(prefix='whalenode-ip-pool-')
    _atexit.register(_bundle.cleanup)
    for _name, _data in '''+repr(files)+'''.items():
        _pathlib.Path(_bundle.name, _name).write_bytes(_base64.b64decode(_data))
    _sys.path.insert(0, _bundle.name)
'''
with (root/'install.sh').open('w', encoding='utf-8', newline='\n') as output:
    output.write(prefix+embedded+loader+(root/'installer.py').read_text(encoding='utf-8')+'\nWHALE_INSTALLER_PY\n')
