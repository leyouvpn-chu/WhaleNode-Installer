"""Generate a dependency-free shell entry embedding the Python scanner."""
from pathlib import Path
root=Path(__file__).resolve().parent
prefix='''#!/usr/bin/env bash
set -eu
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
if ! command -v python3 >/dev/null 2>&1; then
  echo '需要 Python 3；Debian/Ubuntu：apt-get install -y python3 iproute2 curl ca-certificates' >&2
  exit 2
fi
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,7) else 2)' || {
  echo '需要 Python 3.7 或更新版本' >&2; exit 2;
}
exec python3 - "$@" <<'WHALE_PUBLIC_IP_SCAN_PY'
'''
(root/'scan-public-ips.sh').write_text(prefix+(root/'scan_public_ips.py').read_text(encoding='utf8')+'\nWHALE_PUBLIC_IP_SCAN_PY\n',encoding='utf8',newline='\n')
