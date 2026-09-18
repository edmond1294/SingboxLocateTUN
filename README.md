# VPS 全局代理出口管理脚本

基于 **sing-box TUN** 的 VPS 全局代理出口管理脚本。

通过简单的菜单即可为 VPS 配置全局代理出口，支持直接粘贴代理节点链接，自动解析节点参数并生成 sing-box 配置。

## 支持协议

目前支持：

* VLESS + WS
* VLESS + WS + TLS
* VLESS + Reality
* SOCKS5 / SOCKS5H
* HTTP / HTTPS
* Trojan
* NaiveProxy
* AnyTLS
* Hysteria2 / HY2
* TUIC
* Shadowsocks
* Shadowsocks 2022 / SS2022

## 主要功能

* 自动检测系统
* 自动安装依赖
* 自动安装 sing-box
* 自动创建 systemd 服务
* TUN 全局代理
* VPS 全局出站代理
* 支持 IPv4 / IPv6
* DNS 劫持
* 自动解析代理链接
* 修改代理出口
* 开启 / 关闭全局代理
* 查看运行状态
* 测试代理连接
* 查看 sing-box 配置
* 查看运行日志
* 重启 sing-box
* 卸载配置
* `out` 快速打开管理菜单
* 一键安装

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/edmond1294/SingboxLocateTUN/main/proxy.sh)
```

## 快速使用

安装完成后直接执行：

```bash
out
```

即可打开管理菜单。

菜单中可以进行代理出口配置、全局代理控制以及 sing-box 服务管理。

## 节点配置

进入菜单后选择代理出口，然后粘贴完整节点链接。

### VLESS WS

```text
vless://UUID@example.com:80?encryption=none&security=none&type=ws&host=example.com&path=/xxx
```

### VLESS WS + TLS

```text
vless://UUID@example.com:443?encryption=none&security=tls&sni=example.com&type=ws&host=example.com&path=/xxx
```

### VLESS Reality

```text
vless://UUID@example.com:443?encryption=none&security=reality&sni=example.com&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&type=tcp
```

### SOCKS5

```text
socks5://username:password@example.com:1080
```

也支持：

```text
socks://username:password@example.com:1080
```

以及：

```text
socks5h://username:password@example.com:1080
```

### HTTP / HTTPS

```text
http://username:password@example.com:8080
```

HTTPS：

```text
https://username:password@example.com:443
```

### Trojan

```text
trojan://password@example.com:443?sni=example.com
```

### NaiveProxy

```text
naive+https://username:password@example.com:443
```

### AnyTLS

```text
anytls://password@example.com:443?sni=example.com
```

### Hysteria2

```text
hysteria2://password@example.com:443?sni=example.com
```

也支持：

```text
hy2://password@example.com:443?sni=example.com
```

### TUIC

```text
tuic://UUID:password@example.com:443?sni=example.com
```

### Shadowsocks

```text
ss://method:password@example.com:8388
```

### Shadowsocks 2022

例如：

```text
ss://2022-blake3-aes-256-gcm:KEY@example.com:8388
```

## 工作原理

开启全局代理后，网络流量通过 sing-box TUN 接管：

```text
┌──────────────┐
│     VPS      │
│              │
│  应用 / 程序  │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ sing-box TUN │
│   singtun0   │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  代理出口节点 │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│   Internet   │
└──────────────┘
```

通过 TUN 接管 VPS 的网络流量，并将流量交给配置的代理出口节点。

## 配置文件

默认配置文件：

```text
/etc/sing-box/config.json
```

sing-box 服务：

```text
sing-box.service
```

### 查看服务状态

```bash
systemctl status sing-box
```

### 重启服务

```bash
systemctl restart sing-box
```

### 停止服务

```bash
systemctl stop sing-box
```

### 查看实时日志

```bash
journalctl -u sing-box -f
```

### 查看当前配置

```bash
cat /etc/sing-box/config.json
```

## 管理菜单

运行：

```bash
out
```

即可打开 VPS 出口管理菜单。

常用功能包括：

```text
1. 更换代理出口
2. 开启全局代理
3. 关闭全局代理
4. 查看运行状态
5. 测试代理
6. 查看配置
7. 查看日志
8. 重启 sing-box
9. 卸载
```

具体菜单内容以当前脚本版本为准。

## Root 权限

由于脚本需要：

* 创建 TUN
* 修改路由
* 管理 DNS
* 管理 systemd 服务
* 修改系统网络配置

建议使用 **root 用户**执行。

例如：

```bash
sudo -i
```

然后执行安装命令。

## SSH 连接注意事项

开启全局代理或修改 VPS 路由之前，建议：

**保留一个备用 SSH 会话。**

如果代理节点配置错误、节点无法连接或路由配置异常，可能导致 VPS 无法正常访问外部网络。

保留备用 SSH 连接可以方便进行故障恢复。

## 代理节点注意事项

请确保使用的代理节点本身可以正常连接。

不同协议需要对应正确的认证参数。

### VLESS Reality

需要：

* UUID
* SNI
* Public Key
* Short ID
* Fingerprint

### VLESS WS

需要：

* UUID
* SNI（TLS 模式）
* Host
* Path

### SOCKS5

需要：

* 服务器地址
* 端口
* 用户名（如果需要）
* 密码（如果需要）

### HTTP / HTTPS

需要：

* 服务器地址
* 端口
* 用户名（如果需要）
* 密码（如果需要）

### Trojan

需要：

* 服务器地址
* 端口
* 密码
* TLS / SNI 参数

### NaiveProxy

需要：

* 服务器地址
* 端口
* 用户名
* 密码
* HTTPS 参数

### AnyTLS

需要：

* 服务器地址
* 端口
* 密码
* TLS / SNI 参数

### Hysteria2

需要：

* 服务器地址
* 端口
* 密码
* TLS 参数

### TUIC

需要：

* UUID
* 密码
* 服务器地址
* 端口
* TLS 参数

### Shadowsocks

需要：

* 加密方式
* 密码
* 服务器地址
* 端口

### SS2022

需要：

* 对应的 Shadowsocks 2022 加密方式
* 密钥
* 服务器地址
* 端口

## IPv4 / IPv6

脚本支持 VPS 的 IPv4 / IPv6 网络环境。

可以使用以下命令测试 VPS 当前出口：

```bash
curl -4 https://api.ipify.org
```

IPv6：

```bash
curl -6 https://api64.ipify.org
```

开启代理后，可以通过测试结果确认 VPS 的公网出口是否已经切换到代理节点。

## sing-box

本项目使用 **sing-box** 作为核心代理程序。

官方文档：

https://sing-box.sagernet.org/

## 项目用途

适用于：

* VPS 全局代理
* NAT VPS 出口代理
* VPS 出口切换
* 第三方代理作为 VPS 出口
* 多协议代理节点管理
* VPS 网络环境测试
* VPS 网络出口管理

## 项目特点

### 一键安装

无需手动创建复杂的 sing-box 配置。

运行安装命令即可完成基础环境配置。

### 节点链接解析

直接粘贴代理节点链接，脚本自动解析节点参数并生成 sing-box 配置。

### TUN 全局代理

使用 sing-box TUN 接管 VPS 网络流量，实现 VPS 全局代理出口。

### 出口切换

可以通过管理菜单快速更换代理节点，而无需手动编辑 JSON 配置文件。

## 故障排查

如果 sing-box 无法启动，可以首先查看日志：

```bash
journalctl -u sing-box -n 100 --no-pager
```

检查配置：

```bash
sing-box check -c /etc/sing-box/config.json
```

查看服务：

```bash
systemctl status sing-box
```

查看当前配置：

```bash
cat /etc/sing-box/config.json
```

如果 `out` 无法启动管理菜单，可以直接执行：

```bash
/usr/local/bin/vps-out
```

## 卸载

进入：

```bash
out
```

然后选择卸载功能。

脚本会处理 sing-box 服务及相关配置。

## 开源说明

本项目仅用于：

* 学习
* 研究
* 合法的网络环境测试
* VPS 网络管理

使用者应遵守所在地法律法规以及代理服务提供商的使用条款。

## License

MIT License
