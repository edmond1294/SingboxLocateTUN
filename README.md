# VPS 全局代理出口管理脚本

基于 **sing-box TUN** 的 VPS 全局代理出口管理脚本。

通过简单的菜单即可为 VPS 配置全局代理出口，支持直接粘贴代理节点链接，自动解析节点参数并生成 sing-box 配置。

## 支持协议

目前支持：

* VLESS + WS + TLS
* VLESS + Reality
* SOCKS5 / SOCKS5H
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

也可以直接执行：

```bash
vps-out
```

## 节点配置

进入菜单后选择代理出口，然后粘贴完整节点链接。

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
│  应用/程序    │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ sing-box TUN │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ 代理出口节点  │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│    Internet  │
└──────────────┘
```

## 配置文件

默认配置文件：

```text
/etc/sing-box/config.json
```

sing-box 服务：

```text
sing-box.service
```

查看服务状态：

```bash
systemctl status sing-box
```

重启服务：

```bash
systemctl restart sing-box
```

停止服务：

```bash
systemctl stop sing-box
```

查看实时日志：

```bash
journalctl -u sing-box -f
```

查看当前配置：

```bash
cat /etc/sing-box/config.json
```

## 管理菜单

运行：

```bash
out
```

可以进行代理管理。

常用功能包括：

```text
配置代理出口
开启全局代理
关闭全局代理
查看运行状态
测试代理
查看配置
查看日志
重启服务
卸载
```

## 注意事项

### Root 权限

由于需要创建 TUN、修改路由以及管理 systemd 服务，建议使用 `root` 用户执行。

### SSH 连接

开启全局代理和修改路由前，建议保留一个备用 SSH 会话。

如果代理节点配置错误，可能导致 VPS 无法正常访问外部网络。

### 代理节点

请确保使用的代理节点本身可以正常连接。

不同协议需要对应正确的认证参数，例如：

* VLESS Reality：UUID、SNI、Public Key、Short ID
* VLESS WS：UUID、SNI、Host、Path
* AnyTLS：密码、服务器地址、端口
* Hysteria2：密码、TLS 参数
* TUIC：UUID、密码、TLS 参数
* Shadowsocks：加密方式、密码
* SS2022：对应的 2022 加密方式和密钥

## sing-box

本项目使用 sing-box 作为核心代理程序。

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

## 开源说明

本项目仅用于学习、研究以及合法的网络环境测试。

使用者应遵守当地法律法规以及代理服务提供商的使用条款。

## License

MIT License
