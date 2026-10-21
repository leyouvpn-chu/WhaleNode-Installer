WhaleNode-Installer — public server-shell entry (initial version)

用途
在新 Linux 节点上运行公开安装脚本；后台地址、密钥、制品下载地址通过参数提供。
源码不包含运营方后台地址、资产清单、真实口令或私钥。无需克隆私有运维仓库。
支持 Debian 11+、Ubuntu 22+、CentOS Stream/Rocky/AlmaLinux/RHEL 9+ 的 systemd 主机。
CentOS 7/8 不支持。不替换现有正在运行的代理，不自动卸载未知业务。

先查看帮助（一句话；请先查看源码，生产使用固定提交 URL）
curl -fsSL https://raw.githubusercontent.com/leyouvpn-chu/WhaleNode-Installer/main/install.sh -o /tmp/whale-install.sh && sudo bash /tmp/whale-install.sh --help

安装命令（所有大写占位值需替换；以下是同一条命令）
sudo bash /tmp/whale-install.sh --api-url 'https://NODE_API_HOST' --api-key 'NODE_KEY' --admin-url 'https://PANEL_HOST/api/v1/ADMIN_PATH' --admin-token 'ADMIN_AUTH' --binary-url 'https://ARTIFACT_HOST/whalenode.gz' --binary-sha256 '64位解压后可执行文件SHA256' --source-commit '40位源码提交SHA' --sni 'TESTED_TLS_HOSTNAME' --protocols vless,hy2

安全输入
省略 --api-key 和 --admin-token 后会隐藏输入；也支持 --api-key-file 和 --admin-token-file。
命令行密钥可能进入 shell 历史和进程参数。禁止 bash -x 调用。
管理员凭据不保存，节点 API Key 写入服务用户可读的 0600 配置。
管理员 authorization 值应与面板请求一致，不自动添加 Bearer 前缀。
节点 API Key 没有建节点权限，不能替代管理员凭据。
制品 URL 不应包含长期敏感令牌：该 URL 会保存在 root-only 续跑状态中。
发布包须由运营方提供；公开仓库不分发 WhaleNode 二进制。
安装前校验 SHA256、WhaleNode 产品名、源码提交和 sing-owned 构建配置。
API 请求不跟随重定向，避免将鉴权头转发到其他地址。

可选参数与记忆
--name '美国备用' 自定义节点基础名；不填按 IP 地区自动生成。
--host IPv4 指定公网入口，不填通过 HTTPS 查询出口地址。
--protocols vless,hy2,anytls 可多选，默认 VLESS+REALITY 与 HY2。
--group-ids 1 面板权限组；--route-ids 5,11,12 面板路由组，由运营方核实实际 ID。
--plan 只检测机器资源并显示计划，不安装软件、不修改系统（需已有 Python 3.9+）。
--status 显示安装进度，不显示密钥。
任务保存在 /var/lib/whalenode-installer/state.json。失败续跑保留节点 ID、协议和名称。
面板写请求失败不盲目重试：下次按任务唯一标签核对，避免重复建节点。
已安装任务再次运行不覆盖配置。管理员令牌不记忆，未完成任务续跑需重新提供。

实际行为
创建面板隐藏节点 → 安装经校验的 WhaleNode → 配置服务 → 有界系统调优 → 本机监听检查。
按 CPU affinity/cgroup 配额设置 GOMAXPROCS；按内存/cgroup 上限设置 GOMEMLIMIT。
检测内核 BBR 支持后才启用 BBR/fq；设置有界 socket 缓冲区、队列及 MTU 黑洞探测。
不盲目改 NIC offload/IRQ/RPS/XPS，不宣称静态参数就是最优。当前只列出网卡，未做驱动性能实验。
专用非 root 服务用户；nftables 仅阻断该用户 IPv6 出口，保留主机 IPv6 管理。
本机端口默认 TCP 28443（VLESS）、UDP 24443（HY2）、TCP 30443（AnyTLS）。
不改主机入站防火墙或云安全组，需管理员核实上述端口允许访问。

验收范围与限制
这是公开安装入口初版，不等于原私有运维流程的所有步骤都已迁移。
自动创建节点需要面板兼容 V2Board server/manage/getNodes 和协议 save 接口。
HY2/AnyTLS 使用自签证书及面板 insecure=1，与当前原有部署方式一致。
仅检查本机服务与监听，不能证明客户端 TCP/UDP 隧道可用。
节点保持 show=0；公网协议测试、产品分组、Grafana/Zabbix 集成仍由私有运维流程验收后发布。
当前没有自动发布开关，不会把监听成功当成伊朗或俄罗斯连通成功。
尚未完成干净机器端到端安装验收；已通过 Linux 单元测试、shell 语法、帮助及只读计划验证。
失败可能留下隐藏面板行和部分本机配置；不会删除已有面板行。
系统调优前值记录于 /var/lib/whalenode-installer/sysctl-before.json，需逐项核对后恢复。

开发验证
python3 build_bootstrap.py 生成内嵌 Python 的单文件 install.sh。
python3 -m unittest -v test_installer
bash -n install.sh
不需要 pip 依赖或本地 Go/npm 编译。请勿提交运行状态、后台配置或任何密钥。
