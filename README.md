# WhaleNode 一键安装器

## 统一中文数字菜单

本分支提供单文件菜单入口，旧服务器也可直接下载运行，不需要事先安装扫描模块：

```bash
curl -fsSL https://raw.githubusercontent.com/leyouvpn-chu/WhaleNode-Installer/feat/unified-node-menu-20261026/install.sh -o /root/whale-manager.sh && bash /root/whale-manager.sh
```

菜单包含：1 安装/续跑；2 节点与监控状态；3 公网 IPv4 扫描；4 IP 池与开机巡检；5 原节点隐藏/恢复；6 本机诊断；7 资源重新调参；8 卸载；0 退出。每次操作返回菜单，支持错误提示和取消。`bash /root/whale-manager.sh` 可重复进入。

有现成的安装参数时，在原参数后添加 `--menu`，参数只传给相关操作，扫描不需要面板凭据。旧命令的 `--non-interactive`、`--status`、`--check` 等自动化调用保留；不要与 `--menu` 混用。首次安装/面板操作仍须提供原有凭据，不把管理员令牌写进公开脚本。

IP 子菜单的开机/定时任务只做发现、验证和保存计划；通用批量建节点/自动换 IP 尚未接通，界面明确说明。状态页显示的是本机服务状态，不把它当成集中监控数据新鲜度或公网验收。原安装器的隐藏/恢复不包括另外创建的附加 IP 实例。检测到附加实例时阻止旧卸载与回滚删除共用核心、监控或出口规则。

验证：whale-dr 109 项回归通过，包含实际控制终端按键测试。实机运行菜单与扫描不等于重新验收所有安装、发布和卸载路径；这些写入路径未为测试而在生产重跑。

> 公网 IP 池的自动执行部分仍为候选功能。`--ip-pool` 的启停、替换操作目前只保存计划，输出 `applied=false`；生产执行适配器尚未接通，不能用于宣称自动搭建或自动换 IP 已完成。原单 IP 安装流程保持独立。

开发分支可用入口：`bash install.sh --ip-pool status`、`scan`、`history`、`lock IP`、`unlock IP`、`pause`、`resume`、`enable IP`、`disable IP`、`replace OLD_IP NEW_IP`。`install-watch` 安装开机与定时**发现**任务，`stop-watch` 停止后续定时发现；两者均不自动更改面板。私网、CGNAT、网卡未绑定或出口验证不符的地址不能进入启用计划。

多 IP 实例配置生成与源站对账候选文件分别位于 `ip_pool_runtime.py`、`server/whalenode_enroll_sync.py`。尚待服务器限定权限的执行通道、旧服务迁移、调度容量共享和真实多公网 IP 验收。不要直接替换生产源站对账脚本。

在 Linux 新服务器的 SSH 终端执行，进入中文安装向导。默认创建 **VLESS（REALITY）+ Hysteria2**，也可选择 AnyTLS。脚本公开；后台地址、密钥和后端制品由运营方在安装时提供，不内置在仓库中。

## 新服务器怎么执行

以 root 登录，用下面这一整行启动安装，**不要追加 `--help`**：

```bash
curl -fsSL https://raw.githubusercontent.com/leyouvpn-chu/WhaleNode-Installer/feat/unified-node-menu-20261026/install.sh -o /root/whalenode-install.sh && bash /root/whalenode-install.sh
```

下载地址不能直接作为 shell 命令执行。下载和执行必须使用同一个文件名。`--help` 只显示帮助，不会安装。

如果系统没有 curl，Debian/Ubuntu 先执行 `apt-get update && apt-get install -y curl ca-certificates`；CentOS Stream/Rocky/AlmaLinux 使用 `dnf install -y curl ca-certificates`。建议通过 SSH 或网页 XTerm.js 操作；传统 NoVNC 文本控制台可能无法显示中文字形。

### 第一次需要填写什么

| 顺序 | 内容 | 说明 |
| --- | --- | --- |
| 1 | 节点 API 的 HTTPS 地址 | 节点连接面板的地址 |
| 2 | 面板管理 API 前缀 | 包含 `/api/v1/实际管理路径`，不是管理网页地址 |
| 3 | 协议 | 回车选择 `vless,hy2`；多选示例 `vless,hy2,anytls` |
| 4 | 节点名称 | 回车按公网 IPv4 的国家、城市生成；也可自行命名 |
| 5 | 面板权限组 ID | 默认 `1`；必须确认实际存在并符合产品权限 |
| 6 | 面板路由组 ID | 回车不指定；可填逗号分隔 ID |
| 7 | WhaleNode 发布清单 HTTPS 地址 | 运营方提供，包含当前架构的下载地址、哈希和源码版本 |
| 8 | 节点 API 密钥 | 隐藏输入；不是管理员令牌 |
| 9 | 面板管理员授权值 | 隐藏输入；只用于本次创建和核对节点，不保存 |

管理 API 前缀和授权值应由面板管理员提供。授权值与面板请求的 `Authorization` 内容一致，安装器不会自行添加 `Bearer`。节点 API Key 没有创建节点权限，不能代替管理员授权。

安装器读取机器资源 → 核对面板 → 校验 WhaleNode 制品 → 创建面板节点 → 安装服务及出口规则 → 检查运行文件哈希和协议监听 → 安装 Zabbix 监控 → **直接在面板显示** → 等待源站自动接入。失败会说明原因，可以修复后运行原命令续跑。

**默认安装后直接显示，不做外部可用性测试。** 面板显示后，运营方源站的对账任务（每分钟）会自动完成调度容量登记、网关节点分组和 Zabbix/Grafana 监控清单，完成后安装器提示“源站接入完成”。不希望立即上线时加 `--no-publish`，之后用 `--show` 上线。云安全组仍需放行下表端口；脚本不改云厂商防火墙。

### 再次运行：管理菜单

已安装的机器再次执行同一条命令，会显示当前状态并给出菜单：

| 选项 | 作用 |
| --- | --- |
| 1 本机自检 | 同 `--check` |
| 2 面板隐藏 | 用户不再收到这台节点（同 `--hide`） |
| 3 面板重新显示 | 同 `--show` |
| 4 卸载 | 隐藏并删除面板节点，停止并移除 WhaleNode、出口规则、系统参数和 Zabbix 监控；源站随后自动删除监控资产和调度登记（同 `--uninstall`，自动化加 `--yes`） |

追加协议：同一条命令把 `--protocols` 改成更多协议（例如 `vless,hy2,anytls`）再运行，会保留已有线路、补建新协议节点、重启后端并显示；不能用这种方式去掉协议。

隐藏、显示和卸载都需要面板管理员授权值（可带 `--admin-token`，否则隐藏输入）。

## 参数与记忆

可以直接带非敏感参数，其余内容由向导询问：

```bash
bash /root/whalenode-install.sh \
  --api-url 'https://panel.example.com' \
  --admin-url 'https://panel.example.com/api/v1/ADMIN_PATH' \
  --release-manifest 'https://downloads.example.com/private/manifest.json' \
  --name '自定义名称' --protocols vless,hy2,anytls --group-ids 1 --node-group legacy_all
```

以上域名和管理路径是占位符，必须换成运营方提供的值。

| 操作 | 命令 |
| --- | --- |
| 查看帮助 | `bash /root/whalenode-install.sh --help` |
| 只看资源和计划 | `bash /root/whalenode-install.sh --plan` |
| 查看任务进度 | `bash /root/whalenode-install.sh --status` |
| 安装后本机自检 | `bash /root/whalenode-install.sh --check` |
| 导出脱敏验收报告 | `bash /root/whalenode-install.sh --check --report-file /root/whalenode-report.json` |
| 失败后续跑 | `bash /root/whalenode-install.sh` |
| 回滚本任务本机变更 | `bash /root/whalenode-install.sh --rollback` |
| 升级 CPU/内存后重新调参 | `bash /root/whalenode-install.sh --retune` |

配置与节点 ID 保存在 `/var/lib/whalenode-installer/state.json`，目录权限 0700、文件 0600。名称、协议、面板地址、下载版本、组和路由会记忆，已创建节点不会因正常续跑重复创建。已完成任务再次运行会核验正在运行的文件和出口规则，不重复安装。

管理员令牌不保存：未完成任务续跑时需要重新提供。节点 API Key 在后端配置生成后可从本机配置复用；更早的失败需要再次提供。记忆只在当前服务器生效，不会自动同步到其他新服务器。不要复制旧任务状态来部署新机器。

自动化可以使用 `--non-interactive`，缺参数直接失败；用 `--api-key-file /root/node-key` 和 `--admin-token-file /root/admin-token` 从权限 0600 的文件读取密钥。也支持 `--api-key`、`--admin-token`，但直接写在命令行可能进入历史和进程参数，优先使用隐藏输入或凭据文件。不要使用 `bash -x`。

其他参数：`--node-group 分组` 指定网关节点分组（默认 `legacy_all`）；`--download-token 令牌` 直接提供私有下载令牌；`--host IPv4` 指定入口 IP；`--sni 域名` 指定已测试的 TLS 域名。默认自动测试候选 SNI 并避开面板中已使用的候选。候选不足会停止，不自动复用。`--binary-url`、`--binary-sha256`、`--source-commit` 可代替发布清单。

## 后端下载与安全边界

仓库不提供 WhaleNode 后端二进制，也不包含运营方 API 地址或密钥。公开脚本本身不需要密码；**访问后端制品的权限由运营方下载服务控制**。支持 HTTPS 私有/签名下载 URL 和 Bearer 下载令牌；本版本不提供 GitHub 私库登录或自建下载鉴权服务。

清单和制品 URL 保存在 root 专属任务状态中，不应使用公开永久链接承载需要保密的二进制。签名 URL 需要覆盖安装/续跑所需时间。清单与制品下载都禁止重定向，请提供最终 HTTPS 地址。下载服务使用 `Authorization: Bearer` 时，可执行：

```bash
bash /root/whalenode-install.sh --download-token-prompt
```

下载令牌隐藏输入，只存在本次进程内，不写入状态、配置或报告。自动化可用 `--download-token-file /root/download-token`，文件必须由 root 所有且无组/其他用户权限，例如 0600；符号链接不接受。此令牌与面板管理员令牌、节点 API Key 分开，不能互相替代。

带下载令牌时，清单和制品必须同源（相同 HTTPS 主机和端口），跨域下载与重定向均拒绝；令牌不会转发给面板或 SNI 测试站点。下载服务还需自行验证令牌、限制权限及有效期。其他鉴权方式应由运营方提供兼容的签名 URL。

示例清单（值均为占位符）：

```json
{
  "schema": 1,
  "architectures": {
    "amd64": {
      "url": "https://downloads.example.com/private/whalenode.gz",
      "sha256": "解压后可执行文件的64位小写SHA256",
      "source_commit": "40位小写源码提交SHA"
    }
  }
}
```

清单可另带顶层 `"monitor": {"url": "...", "sha256": "..."}`，指向运营方的监控接入脚本（含 Zabbix 自动注册 PSK，只放在私有下载后面）；直接显示节点前必须安装监控。`arm64` 使用同样结构。清单按当前架构选择制品；续跑使用已记录的版本，不随远程清单更新自动升级。运营方可用以下工具生成清单，再上传至自己的 HTTPS 下载服务：

```bash
python3 make_manifest.py --archive whalenode.gz \
  --url 'https://downloads.example.com/private/whalenode.gz' \
  --source-commit '实际40位源码提交SHA' --arch amd64 > manifest.json
```

哈希必须是**解压后的可执行文件**，不是 gzip 文件。下载后核对哈希、`version --json` 中的 WhaleNode 产品名、源码提交和 `sing-owned` 构建配置。哈希验证依赖可信清单，不能替代独立的发行签名。不会回退安装 V2bX。

节点密钥保存在 `/etc/whalenode/config.json`，权限 0600，WhaleNode 专用服务用户可读；配置目录权限 0700。管理员令牌不写入状态或后端配置。获得服务器 root 权限的人仍能读取节点密钥，公开脚本不能消除这一权限边界。

## 系统与调优

需 root、systemd、至少 768 MiB 可用配额内存，以及 512 MiB 安装磁盘空间。发行版入口允许 Debian 11+、Ubuntu 22+、CentOS Stream/Rocky/AlmaLinux/RHEL 9+；不支持 CentOS 7/8、Alpine 或无 systemd 容器。架构支持 x86_64/aarch64，但实际可安装性取决于运营方提供相应后端制品。

- 根据 CPU affinity 和 cgroup 配额设置 `GOMAXPROCS`。
- 根据主机/cgroup 内存上限设置 `GOMEMLIMIT` 和有界 socket 缓冲区。
- 检测内核支持后启用 BBR/fq，调整连接队列和 TCP MTU 探测。
- 使用非 root 服务用户和 systemd 文件访问限制，开机自动启动。
- 通过独立 nftables 表阻断 **WhaleNode 用户的 IPv6 出口**，保留主机 IPv6 管理及其他服务。
- 记录修改前的 sysctl；不盲目修改网卡 IRQ、RPS、offload 或强制绑定 CPU，不承诺静态参数在所有线路都达到最佳性能。

| 协议 | 必须放行的默认入站端口 |
| --- | --- |
| VLESS + REALITY | TCP 28443 |
| Hysteria2 | UDP 24443 |
| AnyTLS | TCP 30443 |

脚本不改云安全组或主机入站防火墙。HY2/AnyTLS 当前使用自签证书及面板 `insecure=1`，客户端应匹配这套配置。

## 安装后自检与监控交接

`--check` 不安装软件、不重启服务、不改规则；成功退出码为 0，任何必需检查失败退出码为 1。它检查服务是否运行、进程实际文件哈希、专用用户、配置权限、面板/节点绑定、各协议监听，以及 nftables 中首条规则是否确实拒绝专用用户 IPv6 出口。规则表存在但规则丢失，不能通过。已安装任务重复执行也会做这些检查。

`--status` 和 `--check` 在未安装的新机器上不会创建任务目录；只读操作需要机器已有 Python 3.9+。

`--report-file` 输出 JSON，采用字段白名单，不包含面板地址、API Key、管理员令牌、私有下载地址或下载令牌。文件权限 0600，已有路径或符号链接会拒绝覆盖。即使检查失败也会保留报告，便于定位。报告仍包含节点 IP、名称、节点 ID、版本和资源信息，仅交给可信运维人员，不要公开上传资产信息。

报告明确标注 `scope=local_only`，外部 TCP/UDP、集中监控和节点发布均为 `not_verified`。运维端需要根据报告中的节点身份完成 Zabbix 登记、指标新鲜度检查和 Grafana 资产映射，再完成用户网络实测与发布；导出报告本身不会冒充这些步骤成功。

## 故障与回滚

```bash
systemctl status whalenode whalenode-egress --no-pager
journalctl -u whalenode -n 80 --no-pager
bash /root/whalenode-install.sh --status
```

分享日志前先遮盖后台地址和敏感字段。常见原因包括管理员权限/管理路径错误、下载链接过期、制品哈希错误、端口已被其他服务占用、候选 SNI 不可达。

脚本拒绝接管未知配置和现有代理服务。面板写请求遇到超时不会立即重复提交，下次按持久任务标签核对记录。不要通过删除状态文件“重试”，否则会丢失关联和回滚依据。

`--retune` 用于云主机升级配置之后：v0.3.4 及以前把后端可用 CPU 核数（GOMAXPROCS）、内存上限（GOMEMLIMIT）和套接字缓冲按安装时的配置写死，升级后仍按旧配置运行；同时旧版把网卡队列设成 `fq`，会把 HY2 单个 UDP 套接字的全部流量当成一条流限到 100 个包。`--retune` 按当前配置重算这些值、把 `fq` 换成 `fq_codel`，上限有变化时重启后端（断线几秒）。

`--rollback` 停止并禁用本任务服务，移除本任务 nftables 表和配置文件、恢复记录的 sysctl。它会中断该节点流量；保留本机密钥配置、任务状态、已下载制品和面板行，以便续跑。不是彻底卸载；彻底移除用 `--uninstall`。

## 兼容与验收范围

面板需兼容 `server/manage/getNodes` 和 `server/{vless,hysteria,anytls}/save` 管理接口，以及 WhaleNode 使用的节点接口。不同 V2Board 分支不保证兼容。

安装器负责本机后端、面板节点、Zabbix agent 和有界调优；调度登记、网关节点分组、监控清单与 Grafana 映射由运营方源站的对账任务按面板标签自动完成。公开仓库不含任何监控凭据。安装器不做目标国家网络验收，节点上线后的实际可用性需要运营方观察，必要时用 `--hide` 撤回。

## 实测记录

见 [基础安装与协议验收记录](TESTING.md) 和 [v0.2.1 自检与下载鉴权验收](TESTING-v0.2.1.md)。只把实际测试过的系统、架构和网络范围列为已验证，不将发行版兼容入口当作测试结果。

## 开发检查

无需 pip 依赖或 Go/npm 编译。修改 Python 源码后需重新生成单文件入口：

```bash
python3 build_bootstrap.py
python3 -m unittest -v test_installer
bash -n install.sh
```

完整安装验收应在隔离的 systemd 虚拟机上进行，使用测试面板数据及真实后端验证协议流量，不能仅靠单元测试或端口监听报告上线成功。

### 自动 SNI 分配

优先未使用的域名；不足或测试失败时，按面板节点记录使用次数从少到多复用，同次数随机。隐藏节点也计入，单条记录的重复字段只计一次，本次新选择随即计入。所有自动选择都在安装机验证 TLS 和证书，VLESS 必须为 TLS 1.3。

候选来源是历史机队池，以及现有 `reality-dest-finder` 扫描记录经 whale-dr 重新筛选的结果，不是手工列举官网。新域名通过 TLS 1.3、h2、X25519、证书链长度、非跳转和额外证书校验；本轮没有俄罗斯住宅或真实代理传输验证，不声明抗封锁可用。具体新增域名、时间和来源见 `sni-pool-provenance.json`。

安装器在需要自动分配新 SNI 时，从发布清单同目录的固定 `sni-pool.json` 获取最新候选，使用原有下载令牌、严格同源且拒绝重定向。服务端每 6 小时用现有 finder 重新筛选，原子替换清单；增删候选只需更新服务端数据，不需要更新安装器版本。更新失败保留上次有效池，明显大面积失败也不覆盖。清单含测量时间和内容 revision。

本机保存最近有效清单（最长 7 天）；网络错误、清单损坏或时间倒退时使用有效缓存，无缓存则明确提示使用内置应急候选。缓存不保存令牌，所有自动选择仍须本机 TLS 验证。已部署/已记录的 SNI 不自动轮换，以免旧订阅失效。

`import_sni_pool.py` 仅用于维护内置应急快照；日常更新不运行该脚本、不重新生成安装器。旧 v0.3.4/v0.3.5 需要一次升级以获得动态读取能力，此后候选更新与安装器版本无关。仍可用 `--sni` 指定已验证域名。

追加协议/续跑自动沿用已保存节点分组，命令携带不同分组时明确提示忽略，不迁移已有节点；旧记录缺失时按本任务面板节点的 `wn-group:` 标签恢复，无法唯一恢复则停止并保留运行服务。预检期间核对已有后端哈希和监听 PID，允许本任务已有监听端口；参数、后台、SNI、下载和节点核对失败不提前停后端。应用新配置时仍需短暂停机重启。
