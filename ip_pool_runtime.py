"""Render independent address instances with explicitly source-bound egress.

Rendering alone is not deployment acceptance: the actual owned core must pass
source-address and protocol tests before a controller can publish an instance.
"""
import copy
import re
from ip_pool import public_ipv4


def render(slot, address, nodes, binary_sha256, cpu, memory_mib):
    if not re.fullmatch('[a-f0-9]{12}',slot) or not public_ipv4(address):
        raise ValueError('无效槽位或公网 IPv4')
    if not re.fullmatch('[a-f0-9]{64}',binary_sha256):
        raise ValueError('缺少受验 WhaleNode 哈希')
    if not isinstance(cpu,int) or cpu<1 or not isinstance(memory_mib,int) or memory_mib<512:
        raise ValueError('实例资源预算不足')
    if not nodes or len(nodes)>2:
        raise ValueError('实例需要 VLESS/HY2 配置')
    protocols=set()
    directory='/etc/whalenode/ip-pool/'+slot
    rendered=[]
    for source in nodes:
        node=copy.deepcopy(source)
        protocol=node.get('NodeType')
        if protocol not in ('vless','hysteria2') or protocol in protocols:
            raise ValueError('仅支持每实例独立的 VLESS/HY2')
        protocols.add(protocol)
        if not isinstance(node.get('NodeID'),int) or node['NodeID']<1:
            raise ValueError('缺少已登记节点 ID')
        node.update(Core='sing',ListenIP=address,SendIP=address,Name=slot+'-'+protocol)
        cert=node.setdefault('CertConfig',{})
        cert.update(CertFile=directory+'/'+protocol+'.cer',KeyFile=directory+'/'+protocol+'.key')
        rendered.append(node)
    # SendIP is not sufficient for the sing core. Its original options explicitly
    # bind direct outbound sockets, with no unbound fallback outbound.
    original={'outbounds':[{'type':'direct','tag':'bound-egress','inet4_bind_address':address}],
              'route':{'final':'bound-egress','rules':[]}}
    config={'Log':{'Level':'warn','Output':''},
            'Cores':[{'Type':'sing','Log':{'Level':'warn'},'OriginalPath':directory+'/sing_original.json'}],
            'Nodes':rendered}
    unit=f'''[Unit]
Description=WhaleNode public IPv4 slot {slot}
After=network-online.target whalenode-egress.service
Wants=network-online.target
Requires=whalenode-egress.service
[Service]
User=whalenode
Group=whalenode
Slice=whalenode-ip-pool.slice
WorkingDirectory={directory}
UMask=0077
Environment=GOMAXPROCS={cpu}
Environment=GOMEMLIMIT={int(memory_mib*.75)}MiB
MemoryMax={memory_mib}M
CPUQuota={cpu*100}%
TasksMax=128
ExecStart=/opt/whalenode/releases/{binary_sha256} server -c {directory}/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=262144
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths={directory}
[Install]
WantedBy=multi-user.target
'''
    return {'directory':directory,'config':config,'original':original,
            'unit_name':'whalenode-ip-'+slot+'.service','unit':unit}


def shared_budget(cpu,memory_mib):
    if not isinstance(cpu,int) or cpu<1 or not isinstance(memory_mib,int) or memory_mib<768:
        raise ValueError('服务器资源预算无效')
    cap=int(memory_mib*.7)
    return f'[Unit]\nDescription=Shared resource budget for all IP instances\n[Slice]\nCPUQuota={cpu*100}%\nMemoryHigh={int(cap*.85)}M\nMemoryMax={cap}M\nTasksMax=512\n'
