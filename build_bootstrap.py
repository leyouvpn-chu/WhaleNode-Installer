"""Generate the single-file shell entry; no dependencies or compilation."""
from pathlib import Path
root=Path(__file__).resolve().parent
prefix='''#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
WhaleNode Linux 一键安装器（需 root、systemd，支持 x86_64/aarch64）

当前显示的是使用帮助，尚未安装或修改节点。

首次安装必填参数：
  --api-url 地址          节点连接后台的 HTTPS 地址
  --admin-url 地址        面板管理 API 前缀（包含 /api/v1/管理路径）
  --binary-url 地址       WhaleNode 的 gzip 发布包下载地址
  --binary-sha256 校验值  解压后可执行文件的 SHA256
  --source-commit 提交号  发布包对应的完整 40 位源码提交号
  --sni 域名              已测试可用的 TLS 域名

敏感参数（省略后隐藏输入，不在终端显示）：
  --api-key 密钥          节点 API 密钥
  --admin-token 凭据      面板管理员授权值，仅本次使用，不保存
  --api-key-file 文件     从本机文件读取节点密钥
  --admin-token-file 文件 从本机文件读取管理员凭据

可选参数：
  --protocols vless,hy2   协议多选，默认 VLESS+REALITY 与 HY2，另支持 anytls
  --name 名称            自定义名称；省略按地区自动生成
  --host IPv4            公网入口 IP；省略自动识别
  --group-ids 1           面板权限组 ID，逗号分隔
  --route-ids 5,11,12     面板路由组 ID，需核实后台实际配置
  --plan                 只查看资源与计划，不安装（需已有 Python 3.9+）
  --status               查看已保存的任务进度
  --help                 显示本帮助

注意：节点 API 密钥不等于管理员授权值，自动建节点需要两者。
安装后节点保持隐藏，公网 TCP/UDP 协议测试、产品分组和监控验收完成后再发布。
当前不是完整的逐项输入向导，非敏感必填项仍需通过命令参数提供。
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
  [[ "$arg" != "--plan" && "$arg" != "--status" ]] || read_only=true
done
if [[ "$read_only" == false ]]; then
  [[ -d /run/systemd/system ]] || { echo '需要使用 systemd 的服务器' >&2; exit 1; }
  if command -v apt-get >/dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 ca-certificates nftables iproute2 procps kmod passwd
  else
    dnf install -y python3 ca-certificates nftables iproute procps-ng kmod shadow-utils
  fi
fi
python3 -c 'import sys; assert sys.version_info >= (3,9), "需要 Python 3.9 或更新版本"'
exec python3 - "$@" <<'WHALE_INSTALLER_PY'
'''
(root/'install.sh').write_text(prefix+(root/'installer.py').read_text(encoding='utf-8')+'\nWHALE_INSTALLER_PY\n',encoding='utf-8',newline='\n')
