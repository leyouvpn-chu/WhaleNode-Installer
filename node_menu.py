"""Unified operator menu. Reuses existing operations without claiming plans apply."""
import json
import sys
from pathlib import Path
import installer as i
import ip_pool_cli as pool
import scan_public_ips as scanner


def multi_ip_present():
    return i.has_additional_ip_instances()


def status():
    i.main(['--status'])
    for service in ('whalenode.service','zabbix-agent2.service','whalenode-ip-pool.timer'):
        p=i.run('systemctl','show',service,'-p','LoadState','-p','ActiveState','-p','MainPID',check=False)
        print(service+'\n'+p.stdout.strip())
    for path in sorted(Path('/etc/systemd/system').glob('whalenode-ip-*.service')):
        if path.name=='whalenode-ip-pool.service':continue
        print(path.name+'\n'+i.run('systemctl','show',path.name,'-p','ActiveState','-p','MainPID',check=False).stdout.strip())
    print('这里显示本机服务状态；集中监控新鲜数据和公网可用性需另外验证。')


def panel_menu(base):
    print('1 隐藏原安装器节点（停止订阅下发）\n2 恢复原安装器节点显示\n0 返回')
    if multi_ip_present():
        print('本机有附加 IP 实例：此处仅管理原安装器记录中的节点，不包括附加 IP。')
    choice=i.prompt('请选择','0')
    flag={'1':'--hide','2':'--show'}.get(choice)
    if flag:i.main(base+[flag])


def ip_menu():
    while True:
        print('\n公网 IP 管理\n1 扫描公网 IP（只读）\n2 刷新本机 IP 池\n3 查看 IP 池与操作记录\n4 锁定 IP\n5 解除锁定\n6 开启开机/每五分钟扫描\n7 关闭定时扫描\n8 新增/更换 IP 的当前支持范围\n0 返回')
        choice=i.prompt('请选择','0')
        if choice=='0':return
        if choice=='1':scanner.main([])
        elif choice=='2':pool.main(['scan'])
        elif choice=='3':pool.main(['status']);pool.main(['history'])
        elif choice in ('4','5'):
            ip=i.prompt('请输入 IP（0 返回）','0')
            if ip!='0':pool.main(['lock' if choice=='4' else 'unlock',ip])
        elif choice=='6':pool.main(['install-watch'])
        elif choice=='7':pool.main(['stop-watch'])
        elif choice=='8':
            print('新增 IP：先由运营商分配并绑定网卡，再选择 1 扫描验证。\n'
                  '更换 IP：先验证新 IP，再完成独立节点配置、面板/分组同步和实际传输验收，最后撤下旧入口。\n'
                  '本版本支持自动发现与手动锁定；通用批量建节点和自动替换执行尚未接通。\n'
                  '扫描通过或刷新 IP 池不会创建节点，不会自动替换现有节点。')
        else:print('请输入菜单中的数字。')


def main(base=None):
    base=list(base or [])
    if i.os.geteuid()!=0:raise RuntimeError('请使用 root 或 sudo 运行管理菜单')
    # Reject execution-mode flags: menu options must select exactly one operation.
    forbidden={'--non-interactive','--status','--check','--plan','--retune','--hide','--show','--uninstall','--rollback','--report-file','--yes'}
    if any(value.split('=',1)[0] in forbidden for value in base):
        raise ValueError('--menu 不能与执行模式参数混用；自动化请直接使用原命令参数')
    i.parser().parse_args(base)
    while True:
        installed=(i.ROOT/'state.json').exists()
        print('\n鲸鱼节点管理\n'+('检测到原安装器记录' if installed else '尚未发现原安装器记录，已有服务不会被自动接管'))
        print('1 安装节点 / 继续未完成的安装\n2 查看节点与监控状态\n3 扫描网卡公网 IP\n4 公网 IP 与开机扫描管理\n5 隐藏 / 恢复原节点\n6 本机诊断\n7 按当前 CPU/内存重新调参\n8 卸载原安装器节点\n0 退出')
        try:
            choice=i.prompt('请选择','0')
            if choice=='0':return
            if choice=='1':i.main(base+['--non-interactive'] if installed and json.loads((i.ROOT/'state.json').read_text()).get('phase')=='published' else base)
            elif choice=='2':status()
            elif choice=='3':scanner.main([])
            elif choice=='4':ip_menu()
            elif choice=='5':panel_menu(base)
            elif choice=='6':i.main(['--check'])
            elif choice=='7':
                print('预算变化可能短暂重启原后端。')
                if i.prompt('输入 1 执行，0 返回','0')=='1':i.main(['--retune'])
            elif choice=='8':
                if multi_ip_present():
                    raise RuntimeError('检测到附加 IP 实例，旧卸载会删除共用核心/配置/监控，已阻止；需先制定逐实例卸载操作')
                i.main(base+['--uninstall'])
            else:print('请输入菜单中的数字。')
        except KeyboardInterrupt:
            print('\n已取消当前菜单操作，返回主菜单。')
        except (RuntimeError,ValueError) as error:
            # A missing controlling terminal is not a retryable menu action.
            if '终端' in str(error):raise
            print('操作未完成：'+str(error))

if __name__=='__main__':main(sys.argv[1:])
