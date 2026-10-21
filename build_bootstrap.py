"""Generate the single-file shell entry; no dependencies or compilation."""
from pathlib import Path
root=Path(__file__).resolve().parent
prefix='''#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
WhaleNode server-local installer (root, systemd, Linux x86_64/aarch64).
Required for new installation:
  --api-url HTTPS_ORIGIN --api-key NODE_KEY
  --admin-url HTTPS_ADMIN_API_PREFIX --admin-token ADMIN_AUTH
  --binary-url HTTPS_GZIP_URL --binary-sha256 EXECUTABLE_SHA256
  --source-commit FULL_SHA --sni TESTED_TLS_HOSTNAME
Optional: --host IPv4 --name NAME --protocols vless,hy2,anytls
          --group-ids 1 --route-ids 5,11,12
          --api-key-file PATH --admin-token-file PATH
Omit secret arguments to enter them privately via the terminal.
--plan is read-only (requires Python 3.9+ already installed); --status shows progress.
Panel nodes remain hidden until external acceptance. No arbitrary old-service removal.
HELP
  exit 0
fi
[[ "$EUID" -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
[[ -f /etc/os-release ]] || { echo 'Missing os-release' >&2; exit 1; }
. /etc/os-release
case "$ID" in
 debian) [[ "${VERSION_ID%%.*}" -ge 11 ]] || exit 1 ;;
 ubuntu) [[ "${VERSION_ID%%.*}" -ge 22 ]] || exit 1 ;;
 centos|rocky|almalinux|rhel) [[ "${VERSION_ID%%.*}" -ge 9 ]] || { echo 'RHEL-family 9+ required (CentOS Stream 9/10 supported)' >&2; exit 1; } ;;
 *) echo 'Supported: Debian 11+, Ubuntu 22+, CentOS Stream/Rocky/AlmaLinux/RHEL 9+' >&2; exit 1 ;;
esac
read_only=false
for arg in "$@"; do
  [[ "$arg" != "--plan" && "$arg" != "--status" ]] || read_only=true
done
if [[ "$read_only" == false ]]; then
  [[ -d /run/systemd/system ]] || { echo 'systemd host required' >&2; exit 1; }
  if command -v apt-get >/dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3 ca-certificates nftables iproute2 procps kmod passwd
  else
    dnf install -y python3 ca-certificates nftables iproute procps-ng kmod shadow-utils
  fi
fi
python3 -c 'import sys; assert sys.version_info >= (3,9), "Python 3.9+ required"'
exec python3 - "$@" <<'WHALE_INSTALLER_PY'
'''
(root/'install.sh').write_text(prefix+(root/'installer.py').read_text(encoding='utf-8')+'\nWHALE_INSTALLER_PY\n',encoding='utf-8',newline='\n')
