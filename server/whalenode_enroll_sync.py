#!/usr/bin/env python3
"""源站自动对账：把 WhaleNode 一键安装器建的节点接入调度、节点分组和监控。

只处理面板里带 `wn-installer` 标签的行（安装器写入），按安装任务编号（12 位 hex 标签）
归成一台机器。每分钟由 cron 以 root 运行：

  显示中（任一行 show=1）:
    1. node_ops 登记（缺行才插，不覆盖人工改过的容量/状态）
    2. 入口 IP 加入节点分组（bin/node_group_join.php，复核下发里出现这些线路名）
    3. 监控清单加 AUTO-<编号> 资产，补 Zabbix 显示名，刷新清单/实时指标 item
    4. 全部成功后给面板行打 `wn-synced` 标签（安装器据此报告完成）
  面板行被删除（安装器卸载）:
    删除监控清单资产、Zabbix 主机与本任务 node_ops 行

失败的步骤写 `wn-error:<步骤>` 标签，下一轮继续重试。不处理任何没有安装器标签的行。
"""
import argparse
import base64
import fcntl
import json
import hashlib
import ipaddress
import os
import re
import subprocess
import sys
import time
from pathlib import Path

PANEL_ENV = '/www/wwwroot/whalevpn.top/.env'
GW_ROOT = '/www/wwwroot/api.bcu.edu.kg'
MYSQL = '/www/server/mysql/bin/mysql'
INVENTORY = Path('/opt/zabbix/whale-inventory-base.json')
SCRIPTS = '/opt/zabbix/scripts'
STATE = Path('/var/lib/whalenode-enroll/state.json')
TABLES = {'vless': 'v2_server_vless', 'hysteria': 'v2_server_hysteria', 'anytls': 'v2_server_anytls'}
MARK, SYNCED = 'wn-installer', 'wn-synced'
NONCE = re.compile(r'[a-f0-9]{12}')
GROUP = re.compile(r'[a-z0-9_]{1,48}')
PROVIDER = 'WhaleNode 安装器'


def log(message):
    print(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()) + ' ' + message, flush=True)


def hexstr(value):
    return "CONVERT(X'%s' USING utf8mb4)" % str(value).encode().hex()


def panel_credentials():
    values = {}
    for line in Path(PANEL_ENV).read_text(encoding='utf-8').splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.split('=', 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values['DB_DATABASE'], values['DB_USERNAME'], values['DB_PASSWORD']


def gateway_credentials():
    code = '$c=require "%s/config.php"; echo json_encode([$c["db"]["name"],$c["db"]["user"],$c["db"]["pass"]]);' % GW_ROOT
    return tuple(json.loads(subprocess.run(['php', '-r', code], check=True, capture_output=True, text=True).stdout))


class Db:
    def __init__(self, credentials):
        self.name, self.user, self.password = credentials

    def query(self, sql):
        # 密码走环境变量，不进 argv / ps。
        proc = subprocess.run([MYSQL, '-u' + self.user, self.name, '-N', '-B', '--raw'], input=sql,
                              capture_output=True, text=True, env=dict(os.environ, MYSQL_PWD=self.password), timeout=60)
        if proc.returncode:
            raise RuntimeError('mysql 失败: ' + proc.stderr.strip()[-300:])
        return [line.split('\t') for line in proc.stdout.splitlines() if line]


def zabbix():
    sys.path.insert(0, SCRIPTS)
    from zbx_api import Zbx
    return Zbx()


def parse_tags(raw):
    try:
        tags = json.loads(raw) if raw and raw != 'NULL' else []
    except ValueError:
        return []
    return [str(t) for t in tags] if isinstance(tags, list) else []


def tag_value(tags, prefix):
    for tag in tags:
        if tag.startswith(prefix):
            return tag[len(prefix):]
    return None


def load_assets(panel):
    assets = {}
    for typ, table in TABLES.items():
        for ident, name, host, show, raw in panel.query(
                "SELECT id,name,host,`show`,tags FROM %s WHERE tags LIKE '%%\"%s\"%%'" % (table, MARK)):
            tags = parse_tags(raw)
            if MARK not in tags:
                continue
            nonce = next((t for t in tags if NONCE.fullmatch(t)), None)
            if not nonce:
                continue
            asset = assets.setdefault(nonce, {'nonce': nonce, 'ip': host, 'rows': []})
            asset['rows'].append({'type': typ, 'table': table, 'id': int(ident), 'name': name,
                                  'host': host, 'show': show == '1', 'tags': tags})
    for asset in assets.values():
        tags = [t for row in asset['rows'] for t in row['tags']]
        hosts=sorted({row['host'] for row in asset['rows']})
        asset['ips']=hosts
        asset['active_ips']=sorted({row['host'] for row in asset['rows'] if row['show']})
        management={t[len('wn-management:'):] for t in tags if t.startswith('wn-management:')}
        if len(management)>1:
            raise RuntimeError('同一服务器的管理地址标签不一致')
        if management:
            management=management.pop()
            if not ipaddress.IPv4Address(management).is_global:
                raise RuntimeError('管理地址标签不是公网 IPv4')
            asset['ip']=management
        elif len(hosts)>1:
            raise RuntimeError('多 IP 资产缺少明确的 wn-management 标签，拒绝猜测管理地址')
        group = tag_value(tags, 'wn-group:') or 'legacy_all'
        asset['group'] = group if GROUP.fullmatch(group) else None
        cpu = tag_value(tags, 'wn-cpu:') or '1'
        asset['cpu'] = max(1, min(64, int(cpu))) if cpu.isdigit() else 1
        ssh = tag_value(tags, 'wn-ssh:') or '22'
        asset['ssh_port'] = int(ssh) if ssh.isdigit() and 0 < int(ssh) < 65536 else 22
        asset['base'] = tag_value(tags, 'wn-name:') or asset['ip']
        asset['zbx'] = 'AUTO-' + asset['nonce'].upper()
        asset['fingerprint']=hashlib.sha256(json.dumps(
            sorted((r['type'],r['id'],r['name'],r['host'],r['show']) for r in asset['rows']),
            ensure_ascii=False).encode()).hexdigest()
    return assets


def set_tags(panel, row, add=(), drop_prefix=()):
    tags = [t for t in row['tags'] if not any(t.startswith(p) for p in drop_prefix)]
    for tag in add:
        if tag not in tags:
            tags.append(tag)
    if tags != row['tags']:
        panel.query('UPDATE %s SET tags=%s, updated_at=UNIX_TIMESTAMP() WHERE id=%d' %
                    (row['table'], hexstr(json.dumps(tags, ensure_ascii=False)), row['id']))
        row['tags'] = tags


def ensure_node_ops(gw, asset):
    for row in asset['rows']:
        if not row['show']:
            continue
        cap = min(600, asset['cpu'] * (60 if row['type'] == 'hysteria' else 30))
        gw.query("INSERT INTO node_ops (node_name,server_type,server_id,relay_id,capacity_users,manual_weight,"
                 "status,note,created_at,updated_at) VALUES (%s,%s,%d,NULL,%d,1.00,'active',%s,NOW(),NOW()) "
                 "ON DUPLICATE KEY UPDATE updated_at=updated_at;" %
                 (hexstr(row['name']), hexstr(row['type']), row['id'], cap,
                  hexstr('whalenode-installer %s %s' % (asset['nonce'], time.strftime('%Y-%m-%d')))))
        # 按字节比较：表字段与连接的排序规则不同（unicode_ci vs general_ci），= 会报 1267。
        found = gw.query("SELECT server_type,server_id FROM node_ops WHERE CAST(node_name AS BINARY)=X'%s'" % row['name'].encode().hex())
        if not found or found[0] != [row['type'], str(row['id'])]:
            raise RuntimeError('node_ops 同名行属于其他节点: ' + row['name'])


def join_group(asset):
    if not asset['group']:
        raise RuntimeError('分组标签无效')
    spec = {'group': asset['group'], 'hosts': asset['active_ips'],
            'expect_names': [r['name'] for r in asset['rows'] if r['show']],
            'actor': 'provision:wn-' + asset['nonce'], 'channel': 'provision', 'ref': 'wn-' + asset['nonce']}
    arg = base64.b64encode(json.dumps(spec, ensure_ascii=False).encode()).decode()
    proc = subprocess.run(['/usr/bin/php', 'bin/node_group_join.php', 'config.php', '--spec=' + arg],
                          cwd=GW_ROOT, capture_output=True, text=True, timeout=180)
    result = {}
    for line in proc.stdout.splitlines():
        if line.startswith('{'):
            try:
                result = json.loads(line)
            except ValueError:
                pass
    if proc.returncode != 0 or result.get('ok') is not True:
        raise RuntimeError('入组失败 %s: %s' % (result.get('code') or proc.returncode, result.get('message', '')))


def update_inventory(mutate):
    with open(str(INVENTORY) + '.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = json.loads(INVENTORY.read_text(encoding='utf-8'))
        new = mutate(rows)
        if new is None:
            return False
        mode = INVENTORY.stat().st_mode & 0o777
        tmp = INVENTORY.with_suffix('.json.wn-tmp')
        tmp.write_text(json.dumps(new, ensure_ascii=False, indent=2), encoding='utf-8')
        os.chmod(tmp, mode)
        os.replace(tmp, INVENTORY)
        return True


def reload_zabbix_cache():
    # 新 item 进 server 配置缓存前 history.push 会报「No permissions to referred object」。
    subprocess.run(['docker', 'exec', 'zbx-server', 'zabbix_server', '-R', 'config_cache_reload'],
                   capture_output=True, timeout=60)
    time.sleep(8)


def run_setup(script):
    for attempt in (1, 2):
        proc = subprocess.run(['python3', os.path.join(SCRIPTS, script), '--setup'],
                              capture_output=True, text=True, timeout=600)
        if not proc.returncode:
            return
        if attempt == 1:
            reload_zabbix_cache()
    raise RuntimeError('%s --setup 失败: %s' % (script, (proc.stderr or proc.stdout).strip()[-300:]))


def ensure_monitoring(z, asset, record):
    hosts = z('host.get', {'output': ['hostid', 'host', 'name'], 'filter': {'host': asset['zbx']}})
    if not hosts:
        raise RuntimeError('Zabbix 还没收到 %s 的自动注册' % asset['zbx'])
    entry = {'key': asset['zbx'].replace('-', '_'), 'name': asset['zbx'], 'role': 'landing', 'provider': PROVIDER,
             'ip': asset['ip'], 'ssh_port': asset['ssh_port'], 'aliases': sorted(set(asset['ips']+[asset['ip']])),
             'node_aliases': sorted(r['name'] for r in asset['rows']), 'required_services': ['whalenode']}

    def mutate(rows):
        for row in rows:
            if row.get('key') == entry['key']:
                return None if row == entry else [entry if r is row else r for r in rows]
            if row.get('ip') == entry['ip'] or row.get('name') == entry['name']:
                raise RuntimeError('监控清单已有同 IP/同名资产 %s，未覆盖' % row.get('name'))
        return rows + [entry]
    changed = update_inventory(mutate)
    host = hosts[0]
    display = asset['base']
    if host['name'] != display:
        taken = z('host.get', {'output': ['hostid'], 'filter': {'name': display}})
        if not taken:
            z('host.update', {'hostid': host['hostid'], 'name': display})
    if changed or not record.get('setup_ok'):
        record['setup_ok'] = False
        for script in ('zbx_inventory_refresh.py', 'zbx_live_metrics.py'):
            run_setup(script)
        record['setup_ok'] = True
    # 自动注册不带宕机触发器；缺了它 = 这台死了没人知道（与 node_build step_monitor 同一条）。
    if not z('trigger.get', {'hostids': host['hostid'], 'output': ['triggerid'], 'search': {'description': '停止上报'}}):
        z('trigger.create', {'description': 'Whale: {HOST.NAME} 停止上报 ≥10 分钟 (疑似宕机 / agent 挂 / 断链)',
                             'expression': 'nodata(/%s/system.uptime,10m)=1' % asset['zbx'],
                             'priority': '4', 'manual_close': '1'})
    sample = z('item.get', {'hostids': host['hostid'], 'output': ['lastclock'], 'filter': {'key_': 'system.uptime'}})
    if not any(int(x.get('lastclock') or 0) > time.time() - 300 for x in sample):
        raise RuntimeError('Zabbix 5 分钟内没有新数据')


def retire(gw, z, nonce, record):
    name = 'AUTO-' + nonce.upper()
    update_inventory(lambda rows: [r for r in rows if r.get('key') != name.replace('-', '_')]
                     if any(r.get('key') == name.replace('-', '_') for r in rows) else None)
    hosts = z('host.get', {'output': ['hostid'], 'filter': {'host': name}})
    if hosts:
        z('host.delete', [hosts[0]['hostid']])
    gw.query("DELETE FROM node_ops WHERE CAST(note AS BINARY) LIKE X'%s'" % ('whalenode-installer %s%%' % nonce).encode().hex())
    log('%s 已卸载：清单、Zabbix 主机与 node_ops 已删除（%s）' % (name, record.get('ip')))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true', help='只列出对账对象，不写入')
    args = parser.parse_args()
    panel, gw = Db(panel_credentials()), Db(gateway_credentials())
    assets = load_assets(panel)
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    if args.dry_run:
        print(json.dumps({'assets': assets, 'state': state}, ensure_ascii=False, indent=2))
        return
    # 每次 Zbx() 都会 user.login 新建会话；只有真的有活要干时才登录。
    session = []

    def z(method, params=None):
        if not session:
            session.append(zabbix())
        return session[0](method, params)
    for nonce, asset in assets.items():
        state.setdefault(nonce, {}).update(ip=asset['ip'], rows=[[r['type'], r['id']] for r in asset['rows']])
        if not any(r['show'] for r in asset['rows']):
            continue
        if (all(SYNCED in r['tags'] for r in asset['rows'] if r['show'])
                and state[nonce].get('fingerprint')==asset['fingerprint']):
            continue
        step = 'node_ops'
        try:
            ensure_node_ops(gw, asset)
            step = 'group'
            join_group(asset)
            step = 'monitor'
            ensure_monitoring(z, asset, state[nonce])
        except Exception as exc:  # noqa: BLE001 —— 记录后下一轮重试
            log('%s %s 失败: %s' % (asset['zbx'], step, str(exc)[:300]))
            for row in asset['rows']:
                set_tags(panel, row, add=['wn-error:' + step], drop_prefix=('wn-error:',))
            continue
        for row in asset['rows']:
            if row['show']:
                set_tags(panel, row, add=[SYNCED], drop_prefix=('wn-error:',))
        state[nonce]['fingerprint']=asset['fingerprint']
        log('%s %s 已接入：node_ops + 分组 %s + 监控' % (asset['zbx'], asset['ip'], asset['group']))
    for nonce in [n for n in state if n not in assets]:
        try:
            retire(gw, z, nonce, state[nonce])
            del state[nonce]
        except Exception as exc:  # noqa: BLE001
            log('AUTO-%s 卸载清理失败: %s' % (nonce.upper(), str(exc)[:300]))
    STATE.parent.mkdir(mode=0o700, exist_ok=True)
    tmp = STATE.with_suffix('.tmp')
    tmp.write_text(json.dumps(state, ensure_ascii=False))
    os.replace(tmp, STATE)


if __name__ == '__main__':
    main()
