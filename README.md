# SingboxLocateTUN

## 基於Singbox的落地系統，支援第三方節點

一鍵腳本：
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/edmond1294/SingboxLocateTUN/main/proxy.sh)
```

一个基于 sing-box TUN 的 VPS 全局代理出口管理脚本。

通过简单的菜单即可配置 VPS 全局出站代理，并支持直接粘贴代理订阅/节点链接，脚本会自动解析并生成 sing-box 配置。

支持协议

目前支持：

VLESS + WS + TLS
VLESS + Reality
SOCKS5 / SOCKS5H
AnyTLS
Hysteria2 / HY2
TUIC
Shadowsocks
Shadowsocks 2022 / SS2022

功能
自动检测 Linux 系统
自动安装所需依赖
自动安装 sing-box
TUN 全局代理
VPS 所有出站流量通过代理出口
支持 IPv4 / IPv6
支持 DNS 劫持
支持直接粘贴完整节点链接
自动解析节点参数
支持修改代理出口
支持开启 / 关闭全局代理
支持查看当前配置
支持查看运行状态
支持测试代理连接
支持查看 sing-box 日志
自动创建 systemd 服务
支持使用 out 快速打开管理菜单

使用

安装完成后，可以直接输入：

out

打开管理菜单。

菜单可以进行：

1. 配置代理出口
2. 开启全局代理
3. 关闭全局代理
4. 查看运行状态
5. 测试代理
6. 查看当前配置
7. 查看日志
8. 重启服务
9. 卸载

具体菜单以脚本实际版本为准。

配置代理

选择代理协议后，直接粘贴完整节点链接即可。

例如 VLESS：

vless://UUID@server:443?encryption=none&security=tls&sni=example.com&type=ws&host=example.com&path=/xxx

Reality：

vless://UUID@server:443?encryption=none&security=reality&sni=example.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp

SOCKS5：

socks5://username:password@example.com:1080

AnyTLS：

anytls://password@example.com:443?sni=example.com

Hysteria2：

hysteria2://password@example.com:443?sni=example.com

TUIC：

tuic://UUID:password@example.com:443?sni=example.com

Shadowsocks：

ss://method:password@example.com:8388

SS2022：

ss://2022-blake3-aes-256-gcm:KEY@example.com:8388


工作原理

脚本主要通过 sing-box TUN 模式接管 VPS 的网络流量：

VPS 程序
   │
   ▼
sing-box TUN
   │
   ▼
代理出口
   │
   ▼
目标网站

开启全局代理后，VPS 上的大部分出站连接会通过配置的代理节点访问。

配置文件

默认配置文件：

/etc/sing-box/config.json

sing-box 服务：

sing-box.service

日志：

journalctl -u sing-box -f

查看状态：

systemctl status sing-box

重启：

systemctl restart sing-box

停止：

systemctl stop sing-box
注意事项
1. 建议使用 root 执行

TUN、路由以及 systemd 服务配置需要较高权限，因此建议使用 root 用户运行。

2. 开启全局代理后

VPS 的网络流量会经过配置的代理出口。

如果代理节点不可用，可能会影响 VPS 的正常出站连接。

建议在确认代理节点正常后再开启全局代理。

3. SSH 注意事项

如果 VPS 正在通过 SSH 管理，修改全局路由前建议保持一个备用 SSH 会话，避免代理配置异常导致 SSH 连接中断。

4. 节点参数

不同协议的参数必须正确。

例如：

VLESS Reality 需要正确的 pbk / sid
TLS 节点需要正确的 sni
WS 节点需要正确的 path / host
Hysteria2 需要正确的密码
TUIC 需要正确的 UUID 和密码
SS2022 必须使用对应加密算法所要求的正确密钥
sing-box

本项目使用 sing-box 作为代理核心。

官方项目：

https://sing-box.sagernet.org/

项目说明

本项目主要用于：

VPS 全局代理
NAT VPS 出口代理
VPS 网络出口切换
第三方代理节点作为 VPS 出口
多协议代理节点管理

使用前请确认你拥有代理节点的合法使用权限。
