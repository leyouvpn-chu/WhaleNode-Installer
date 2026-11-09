"""Generate a dependency-free shell entry embedding the Python scanner."""
from pathlib import Path
root=Path(__file__).resolve().parent
prefix='''#!/usr/bin/env bash
set -eu
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
# Debian's non-login shells may omit sbin, where iproute2 installs ip.
export PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin"
if ! command -v python3 >/dev/null 2>&1; then
  echo '需要 Python 3；Ubuntu 20.04 / Debian 11 请先以 root 运行：apt-get update && apt-get install -y python3 iproute2 curl ca-certificates' >&2
  exit 2
fi
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,7) else 2)' || {
  echo '需要 Python 3.7 或更新版本' >&2; exit 2;
}
exec python3 - "$@" <<'WHALE_PUBLIC_IP_SCAN_PY'
'''
# Path.write_text(newline=...) requires Python 3.10; target systems use 3.8/3.9.
with (root/'scan-public-ips.sh').open('w', encoding='utf8', newline='\n') as output:
    output.write(prefix+(root/'scan_public_ips.py').read_text(encoding='utf8')+'\nWHALE_PUBLIC_IP_SCAN_PY\n')
