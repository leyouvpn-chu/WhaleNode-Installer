"""运营方工具：为已有、获准分发的 gzip 制品生成安装清单，不上传任何文件。"""
import argparse,gzip,hashlib,json,re
from pathlib import Path
from urllib.parse import urlsplit
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--archive',type=Path,required=True)
p.add_argument('--url',required=True)
p.add_argument('--source-commit',required=True)
p.add_argument('--arch',choices=['amd64','arm64'],required=True)
a=p.parse_args()
u=urlsplit(a.url)
if u.scheme!='https' or not u.hostname or u.username or u.password or u.fragment:p.error('使用 HTTPS 制品地址，不能内嵌用户名或密码')
if not re.fullmatch('[a-f0-9]{40}',a.source_commit):p.error('源码提交必须是 40 位 SHA')
digest=hashlib.sha256()
with gzip.open(a.archive,'rb') as f:
    for block in iter(lambda:f.read(1024*1024),b''):digest.update(block)
print(json.dumps({'schema':1,'architectures':{a.arch:{'url':a.url,'sha256':digest.hexdigest(),'source_commit':a.source_commit}}},indent=2))
