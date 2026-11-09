# Ubuntu 20.04 / Debian 11 公网 IPv4 扫描

使用系统 Python 3（最低 3.7）、iproute2、curl 和 CA 证书，不需要 pip 或 WhaleNode 安装状态。
精简镜像先以 root 安装依赖：

```sh
apt-get update && apt-get install -y python3 iproute2 curl ca-certificates
bash /root/whale-ip-scan.sh
# 可选：JSON 输出，或仅检测某个网卡
bash /root/whale-ip-scan.sh --json
bash /root/whale-ip-scan.sh --interface eth0
```

扫描器不会自动安装软件、更改网络、重启服务或写入节点 IP 池。不要求 root；普通用户需有读取网卡和发起 HTTPS 请求的权限。
下载 URL 必须指向含本次修改的提交；旧的 `08caa3e` 固定链接不会自动更新。

兼容性处理：补充 Debian 非登录 Shell 的 sbin 搜索路径；生成器使用 Python 3.8/3.9 支持的文件 API；保持旧版 curl 支持的参数；设置 UTF-8 输出。
单个检测站超时不丢弃其他站的结果。只有两个站均返回绑定的源 IP 才标为通过。

退出码：0 全部出口通过；2 依赖、参数或扫描错误；3 存在未确认或出口不一致；4 没有符合条件的公网 IPv4。
云平台已分配但未绑定的地址、私网 NAT 地址和 IPv6 不会列出。出口验证不等于外部 VPN 可达性。

开发验证：`python3 build_ip_scan.py`、`bash -n scan-public-ips.sh`、`python3 -m unittest -v test_scan_public_ips`。

2026-11-09 验证：在固定主机密钥的 whale-dr CI 主机（159.195.243.140）上，以 whalebuild 非特权账户运行 11 项扫描器测试、Shell 语法检查、精简 PATH/C locale 的帮助入口，以及生成文件前后 SHA-256 一致性检查，均通过。Python 3.8/3.9 语法解析通过。实际运行解释器为 Python 3.13.5；尚未在 Ubuntu 20.04 / Debian 11 原生系统上完成实测，不将语法检查等同于目标系统验收。
