"""Import fresh finder-screen results; never promote unverified names."""
import argparse
import datetime
import json
import re
from pathlib import Path

def select(doc):
    finished=datetime.datetime.fromisoformat(doc['finished'])
    age=(datetime.datetime.now(datetime.timezone.utc)-finished).total_seconds()
    if not 0 <= age <= 86400:raise ValueError('Screen results must be less than 24 hours old')
    names=[]
    for row in doc['results']:
        if not (row.get('accepted') and row.get('ok') and row.get('certificate_verified')):continue
        if not (row.get('tls13') and row.get('alpn_h2') and row.get('x25519') and 0 < row.get('chain_bytes',0) < 8192 and not row.get('redirect')):continue
        name=row['domain'].lower().rstrip('.')
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,251}[a-z0-9]',name):raise ValueError('Invalid domain')
        if name not in names:names.append(name)
    if not names:raise ValueError('No verified candidates')
    return names

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('screen');p.add_argument('--base-pool',required=True)
    a=p.parse_args()
    root=Path(__file__).resolve().parent
    doc=json.loads(Path(a.screen).read_text(encoding='utf-8'))
    base=json.loads(Path(a.base_pool).read_text(encoding='utf-8'))['pool']
    added=[n for n in select(doc) if n not in base]
    names=list(dict.fromkeys(base+added))
    code=(root/'installer.py').read_text(encoding='utf-8')
    start=code.index('SNI_POOL=(');end=code.index('\n)'+ '\n',start)+2
    block='SNI_POOL=(\n'+''.join('    '+repr(n)+',\n' for n in names)+')'
    (root/'installer.py').write_text(code[:start]+block+code[end:],encoding='utf-8',newline='\n')
    provenance={'source':'existing reality-dest-finder candidates/bundle_suitable.json, freshly screened',
                'finished':doc['finished'],'origin':doc['origin'],'historical_pool_count':len(base),
                'new_domains':added,'new_domains_ru_residential':'not measured in this run'}
    (root/'sni-pool-provenance.json').write_text(json.dumps(provenance,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('Pool',len(names),'freshly screened additions',len(added))
