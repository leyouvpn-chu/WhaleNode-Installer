# Ubuntu 20.04 / Debian 11 安装入口

兼容分支保留 `7ff7843` 的统一菜单，同时合入 `origin/main` 的 `486dc20` 基线（临时端口配置与回滚、线路名去 IP）。不会把旧菜单分支当成最新安装器。

修复内容：

- Ubuntu 最低版本调整为 20.04；使用系统 Python 3.8+，无需替换系统 Python 或安装 pip 依赖。
- 用兼容 Python 3.8 的参数解析替代 `argparse.BooleanOptionalAction`。保留 `publish=None/True/False` 三态及最后一个开关生效的语义。
- 单文件生成器使用 Python 3.8/3.9 支持的文件 API，并补全 sbin 命令路径。
- 菜单和持久化 IP 巡检同时携带 `ephemeral_ports.py`，保留新的端口管理功能。
- 扫描器复用独立扫描入口的兼容性修复；单个检测站超时不丢弃其他站的结果。
- Debian 11 的官方旧安全源存在索引可读、包下载 404 的情况。Shell 入口仅在本进程树中复制软件源并将官方安全源切到 `archive.debian.org/debian-security`，仍校验仓库签名，不改写系统软件源；退出时清理临时配置。监控安装继承这一临时设置。

精简镜像以 root 先执行：

```sh
apt-get update && apt-get install -y python3 ca-certificates curl iproute2
```

菜单与只读入口不会擅自安装依赖。完整节点安装仍需 root、systemd 和匹配架构的 WhaleNode 制品。

## 监控接入包

原默认下载清单中的监控脚本不支持 Ubuntu 20.04（focal）。仅更换公开 `install.sh` 不足以完成安装，必须配套使用兼容清单：

```text
https://ops.whalevpn.top/whalenode-dl/staging/manifest-ubuntu20-debian11-20261109.json
```

兼容清单复用原清单的 WhaleNode 后端条目，只更换监控接入包。监控新增官方 `zabbix-agent2_7.0.29-1+ubuntu20.04_amd64.deb` 映射，SHA-256 为 `0918ef3c7dbc9593389b80bf4c295733b096d91929239fb4228222407eb0dbd8`，通过 apt 安装本地已校验包以补齐精简镜像依赖。Debian 11 继续使用原 bullseye 包。

下载授权方式保持 Bearer 令牌；凭据不写入公开仓库。当前清单只有 amd64 制品，不能据此宣称 aarch64 已验收。

兼容清单的监控包 SHA-256：`8081fa17a488beb618e35c7285705fa123c420320ce1199ce70852c271b89bba`。已通过真实 HTTPS 授权下载核验；不带授权返回 401。默认 `manifest.json` 未修改，后端条目沿用原清单。

`--node-group legacy_all` 是 Whale / Super VPN 共享交付，不代表 Super Proxy。适配工作不创建节点、不改现有节点所属产品，也不代替真实安装、订阅交付和客户端流量验收。

## 验证记录（2026-11-09）

在固定 SSH 主机密钥的 whale-dr（159.195.243.140）上，从官方 Ubuntu 20.04 / Debian 11 amd64 镜像建立隔离文件系统；使用各自系统 Python 3.8.10 / 3.9.2。每套环境非特权运行 131 项测试（129 通过、2 项需 root 的检查跳过），再于隔离 root 环境运行 3 项入口检查，全部通过，覆盖全部 131 项不同测试。

实测包括生成文件一致性、真实 PTY 菜单输入、与完整安装命令相同结构的占位参数、只读状态/IP 池入口、旧版 iproute2 JSON 扫描、临时软件源原文件保留及成功/失败清理。两个系统对应的官方 Zabbix agent2 7.0.29 包均成功安装并运行 `-V`。

测试单元限制 2 CPU、1 GiB 内存和 10 分钟；依赖及镜像只在备用机，结束后删除临时系统文件，保留日志与源码哈希。首次 Python 3.8 参数解析失败和 Debian 11 测试环境/归档源失败记录均保留，最终通过结果来自修复后的同一源码快照。

这些是共享 CI 内核的发行版用户态环境，不是完整虚拟机。没有执行真实节点部署、监控注册、面板发布、订阅验收或实际 VPN 流量测试；没有重启现有业务服务。
