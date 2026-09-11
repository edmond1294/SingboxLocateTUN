#!/bin/bash

# ============================================================
# VPS 全局出口代理脚本
# sing-box + TUN
# 支持 VLESS WS TLS / SOCKS5 / VLESS Reality
# ============================================================

CONFIG="/etc/sing-box/config.json"
BACKUP="/etc/sing-box/config.json.backup"
SCRIPT="/usr/local/bin/vps-out"
LINK="/usr/local/bin/out"

# ------------------------------------------------------------
# 基础
# ------------------------------------------------------------

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 用户运行此脚本"
    exit 1
fi

mkdir -p /etc/sing-box
mkdir -p /etc/vps-out

# ------------------------------------------------------------
# 安装基础依赖
# ------------------------------------------------------------

install_basic() {

    echo "正在检查基础依赖..."

    if command -v apt-get >/dev/null 2>&1; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y >/dev/null 2>&1

        apt-get install -y \
            curl \
            wget \
            unzip \
            ca-certificates \
            iproute2 \
            iptables \
            python3 \
            openssl \
            >/dev/null 2>&1

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y \
            curl \
            wget \
            unzip \
            ca-certificates \
            iproute \
            iptables \
            python3 \
            openssl \
            >/dev/null 2>&1

    elif command -v yum >/dev/null 2>&1; then

        yum install -y \
            curl \
            wget \
            unzip \
            ca-certificates \
            iproute \
            iptables \
            python3 \
            openssl \
            >/dev/null 2>&1

    elif command -v apk >/dev/null 2>&1; then

        apk add --no-cache \
            curl \
            wget \
            unzip \
            ca-certificates \
            iproute2 \
            iptables \
            python3 \
            openssl \
            >/dev/null 2>&1

    else

        echo "无法识别当前系统的包管理器"
        return 1

    fi

    echo "基础依赖安装完成"
}

# ------------------------------------------------------------
# 安装 sing-box
# ------------------------------------------------------------

install_singbox() {

    clear

    echo "========================================"
    echo "        安装 / 更新 sing-box"
    echo "========================================"
    echo

    install_basic

    echo
    echo "正在安装最新版 sing-box..."
    echo

    if curl -fsSL https://sing-box.app/install.sh | sh; then

        systemctl daemon-reload >/dev/null 2>&1

        if command -v sing-box >/dev/null 2>&1; then
            echo
            echo "sing-box 安装成功"
            echo
            sing-box version
        else
            echo
            echo "sing-box 安装程序执行完成，但没有找到 sing-box"
            return 1
        fi

    else

        echo
        echo "sing-box 安装失败"
        return 1

    fi

    echo
    read -r -p "按回车返回菜单..."
}

# ------------------------------------------------------------
# 检查 sing-box
# ------------------------------------------------------------

check_singbox() {

    if command -v sing-box >/dev/null 2>&1; then
        return 0
    fi

    echo "未检测到 sing-box"
    echo
    echo "请先使用菜单中的「安装 / 更新 sing-box」"
    echo
    return 1
}

# ------------------------------------------------------------
# 安装快捷命令
# ------------------------------------------------------------

install_shortcut() {

    if [ -f "$0" ] && [ "$0" != "/dev/fd/63" ]; then

        cp -f "$0" "$SCRIPT" >/dev/null 2>&1
        chmod +x "$SCRIPT" >/dev/null 2>&1

    fi

    if [ -f "$SCRIPT" ]; then
        chmod +x "$SCRIPT"
        ln -sf "$SCRIPT" "$LINK"
    fi
}

# ------------------------------------------------------------
# 解析 VLESS
# ------------------------------------------------------------

parse_vless() {

    local URL="$1"
    local OUTPUT="$2"

    python3 - "$URL" "$OUTPUT" <<'PY'
import sys
import json
from urllib.parse import urlsplit, parse_qs, unquote

url = sys.argv[1]
output = sys.argv[2]

try:
    u = urlsplit(url)

    if u.scheme.lower() != "vless":
        raise Exception("不是 VLESS 链接")

    uuid = unquote(u.username or "")
    server = u.hostname
    port = u.port

    if not uuid:
        raise Exception("缺少 UUID")

    if not server:
        raise Exception("缺少服务器地址")

    if not port:
        raise Exception("缺少服务器端口")

    q = parse_qs(u.query)

    def get(name, default=""):
        return unquote(q.get(name, [default])[0])

    security = get("security", "").lower()
    transport_type = get("type", "").lower()

    config = {
        "type": "vless",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "uuid": uuid
    }

    # --------------------------------------------------------
    # Reality
    # --------------------------------------------------------

    if security == "reality":

        sni = get("sni")
        fp = get("fp", "chrome")
        pbk = get("pbk")
        sid = get("sid", "")
        flow = get("flow", "")

        if not sni:
            raise Exception("Reality 缺少 sni")

        if not pbk:
            raise Exception("Reality 缺少 pbk")

        config["tls"] = {
            "enabled": True,
            "server_name": sni,
            "utls": {
                "enabled": True,
                "fingerprint": fp
            },
            "reality": {
                "enabled": True,
                "public_key": pbk,
                "short_id": sid
            }
        }

        if flow:
            config["flow"] = flow

    # --------------------------------------------------------
    # TLS + WS
    # --------------------------------------------------------

    elif security == "tls":

        sni = get("sni", server)
        fp = get("fp", "chrome")

        config["tls"] = {
            "enabled": True,
            "server_name": sni
        }

        if fp:
            config["tls"]["utls"] = {
                "enabled": True,
                "fingerprint": fp
            }

        if transport_type == "ws":

            path = get("path", "/")
            host = get("host", "")

            ws = {
                "type": "ws",
                "path": path
            }

            if host:
                ws["headers"] = {
                    "Host": host
                }

            config["transport"] = ws

        elif transport_type == "grpc":

            service_name = get("serviceName", "")

            config["transport"] = {
                "type": "grpc"
            }

            if service_name:
                config["transport"]["service_name"] = service_name

    # --------------------------------------------------------
    # 无 TLS
    # --------------------------------------------------------

    else:

        if transport_type == "ws":

            path = get("path", "/")
            host = get("host", "")

            ws = {
                "type": "ws",
                "path": path
            }

            if host:
                ws["headers"] = {
                    "Host": host
                }

            config["transport"] = ws

    with open(output, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

except Exception as e:

    print("解析失败:", e)
    sys.exit(1)
PY

    return $?
}

# ------------------------------------------------------------
# 解析 SOCKS5
# ------------------------------------------------------------

parse_socks() {

    local URL="$1"
    local OUTPUT="$2"

    python3 - "$URL" "$OUTPUT" <<'PY'
import sys
import json
from urllib.parse import urlsplit, unquote

url = sys.argv[1]
output = sys.argv[2]

try:

    u = urlsplit(url)

    if u.scheme.lower() not in ["socks5", "socks"]:
        raise Exception("不是 SOCKS5 链接")

    server = u.hostname
    port = u.port

    if not server:
        raise Exception("缺少服务器地址")

    if not port:
        raise Exception("缺少服务器端口")

    config = {
        "type": "socks",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "version": "5"
    }

    username = unquote(u.username or "")
    password = unquote(u.password or "")

    if username:
        config["username"] = username

    if password:
        config["password"] = password

    with open(output, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)

except Exception as e:

    print("解析失败:", e)
    sys.exit(1)
PY

    return $?
}

# ------------------------------------------------------------
# 读取当前 SSH 客户端 IP
# 防止配置 TUN 后当前 SSH 连接断开
# ------------------------------------------------------------

get_ssh_ip() {

    SSH_IP=""

    if [ -n "$SSH_CLIENT" ]; then
        SSH_IP="$(echo "$SSH_CLIENT" | awk '{print $1}')"
    fi
}

# ------------------------------------------------------------
# 生成完整 sing-box 配置
# ------------------------------------------------------------

generate_config() {

    local OUTBOUND="$1"

    get_ssh_ip

    python3 - "$OUTBOUND" "$SSH_IP" "$CONFIG" <<'PY'
import sys
import json
import os

outbound_file = sys.argv[1]
ssh_ip = sys.argv[2]
config_file = sys.argv[3]

with open(outbound_file, "r", encoding="utf-8") as f:
    proxy = json.load(f)

# ------------------------------------------------------------
# DNS
# sing-box 1.12+ 新格式
# ------------------------------------------------------------

dns_server = {
    "type": "udp",
    "tag": "dns-remote",
    "server": "1.1.1.1",
    "server_port": 53,
    "detour": "proxy"
}

# ------------------------------------------------------------
# TUN 排除地址
# ------------------------------------------------------------

exclude = [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "::1/128",
    "fc00::/7",
    "fe80::/10"
]

# 当前 SSH 客户端 IP
if ssh_ip:
    if ":" in ssh_ip:
        exclude.append(ssh_ip + "/128")
    else:
        exclude.append(ssh_ip + "/32")

config = {
    "log": {
        "level": "warn"
    },

    "dns": {
        "servers": [
            dns_server
        ],
        "final": "dns-remote",
        "strategy": "prefer_ipv4"
    },

    "inbounds": [
        {
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "singtun0",
            "address": [
                "172.19.0.1/30",
                "fdfe:dcba:9876::1/126"
            ],
            "auto_route": True,
            "strict_route": True,
            "stack": "system",
            "route_exclude_address": exclude
        }
    ],

    "outbounds": [
        proxy,
        {
            "type": "direct",
            "tag": "direct"
        },
        {
            "type": "block",
            "tag": "block"
        }
    ],

    "route": {
        "auto_detect_interface": True,
        "final": "proxy"
    }
}

os.makedirs(os.path.dirname(config_file), exist_ok=True)

with open(config_file, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
PY

    return $?
}

# ------------------------------------------------------------
# 应用代理配置
# ------------------------------------------------------------

apply_proxy() {

    clear

    if ! check_singbox; then
        read -r -p "按回车返回..."
        return
    fi

    echo "========================================"
    echo "              配置全局代理"
    echo "========================================"
    echo
    echo "支持："
    echo "1. VLESS + WS + TLS"
    echo "2. SOCKS5"
    echo "3. VLESS + Reality"
    echo "0. 返回"
    echo

    read -r -p "请选择协议: " TYPE

    clear

    case "$TYPE" in

        1)
            PROTOCOL="vless"
            echo "========================================"
            echo "       VLESS + WS + TLS"
            echo "========================================"
            ;;

        2)
            PROTOCOL="socks"
            echo "========================================"
            echo "             SOCKS5"
            echo "========================================"
            ;;

        3)
            PROTOCOL="reality"
            echo "========================================"
            echo "          VLESS + Reality"
            echo "========================================"
            ;;

        0)
            return
            ;;

        *)
            echo "无效选择"
            read -r -p "按回车返回..."
            return
            ;;

    esac

    echo
    echo "请粘贴完整节点链接："
    echo

    read -r -p "> " NODE

    if [ -z "$NODE" ]; then
        echo
        echo "节点不能为空"
        read -r -p "按回车返回..."
        return
    fi

    TMP_OUT="/etc/vps-out/outbound.json"

    rm -f "$TMP_OUT"

    case "$PROTOCOL" in

        vless)
            parse_vless "$NODE" "$TMP_OUT"
            RESULT=$?
            ;;

        socks)
            parse_socks "$NODE" "$TMP_OUT"
            RESULT=$?
            ;;

        reality)
            parse_vless "$NODE" "$TMP_OUT"
            RESULT=$?
            ;;

    esac

    if [ "$RESULT" != "0" ] || [ ! -s "$TMP_OUT" ]; then

        echo
        echo "节点解析失败"
        echo

        rm -f "$TMP_OUT"

        read -r -p "按回车返回..."
        return
    fi

    # --------------------------------------------------------
    # 备份旧配置
    # --------------------------------------------------------

    if [ -f "$CONFIG" ]; then
        cp -f "$CONFIG" "$BACKUP"
    fi

    # --------------------------------------------------------
    # 生成配置
    # --------------------------------------------------------

    echo
    echo "正在生成 sing-box 配置..."

    generate_config "$TMP_OUT"

    if [ "$?" != "0" ]; then

        echo
        echo "生成配置失败"

        if [ -f "$BACKUP" ]; then
            cp -f "$BACKUP" "$CONFIG"
        fi

        read -r -p "按回车返回..."
        return
    fi

    # --------------------------------------------------------
    # 验证配置
    # --------------------------------------------------------

    echo "正在验证配置..."

    if ! sing-box check -c "$CONFIG"; then

        echo
        echo "========================================"
        echo "配置验证失败"
        echo "========================================"
        echo

        if [ -f "$BACKUP" ]; then
            cp -f "$BACKUP" "$CONFIG"
            echo "已恢复之前的配置"
        else
            rm -f "$CONFIG"
        fi

        echo
        read -r -p "按回车返回..."
        return
    fi

    # --------------------------------------------------------
    # 启动服务
    # --------------------------------------------------------

    echo
    echo "正在启动 sing-box..."

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then

        echo
        echo "========================================"
        echo "代理配置成功"
        echo "========================================"
        echo
        echo "当前 VPS 出站流量已通过 TUN 接管"
        echo "当前节点已作为全局出口"
        echo

    else

        echo
        echo "========================================"
        echo "sing-box 启动失败"
        echo "========================================"
        echo

        echo "最近日志："
        echo

        journalctl -u sing-box --no-pager -n 30

        if [ -f "$BACKUP" ]; then
            echo
            echo "正在恢复旧配置..."

            cp -f "$BACKUP" "$CONFIG"

            systemctl restart sing-box >/dev/null 2>&1
        fi

    fi

    echo
    read -r -p "按回车返回菜单..."
}

# ------------------------------------------------------------
# 关闭全局代理
# ------------------------------------------------------------

disable_proxy() {

    clear

    echo "========================================"
    echo "            关闭全局代理"
    echo "========================================"
    echo

    systemctl stop sing-box >/dev/null 2>&1

    echo "全局代理已关闭"
    echo
    echo "sing-box 服务已停止"
    echo

    read -r -p "按回车返回菜单..."
}

# ------------------------------------------------------------
# 开启代理
# ------------------------------------------------------------

enable_proxy() {

    clear

    echo "========================================"
    echo "            开启全局代理"
    echo "========================================"
    echo

    if [ ! -f "$CONFIG" ]; then
        echo "当前没有代理配置"
        echo
        read -r -p "按回车返回..."
        return
    fi

    if ! sing-box check -c "$CONFIG" >/dev/null 2>&1; then
        echo "当前配置验证失败"
        echo
        read -r -p "按回车返回..."
        return
    fi

    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then
        echo
        echo "全局代理已开启"
    else
        echo
        echo "启动失败"
        echo
        journalctl -u sing-box --no-pager -n 20
    fi

    echo
    read -r -p "按回车返回菜单..."
}

# ------------------------------------------------------------
# 查看状态
# ------------------------------------------------------------

show_status() {

    clear

    echo "========================================"
    echo "              当前状态"
    echo "========================================"
    echo

    if command -v sing-box >/dev/null 2>&1; then

        echo "sing-box：已安装"
        echo
        sing-box version
        echo

    else

        echo "sing-box：未安装"
        echo

    fi

    if systemctl is-active --quiet sing-box; then
        echo "代理状态：运行中"
    else
        echo "代理状态：已关闭"
    fi

    echo

    if [ -f "$CONFIG" ]; then
        echo "配置文件：已存在"
    else
        echo "配置文件：不存在"
    fi

    echo

    if ip link show singtun0 >/dev/null 2>&1; then
        echo "TUN：已创建"
    else
        echo "TUN：未创建"
    fi

    echo
    echo "----------------------------------------"
    echo

    if [ -f "$CONFIG" ]; then

        echo "配置验证："

        if sing-box check -c "$CONFIG" >/dev/null 2>&1; then
            echo "正常"
        else
            echo "失败"
        fi

    fi

    echo
    echo "----------------------------------------"
    echo
    echo "最近日志："
    echo

    journalctl -u sing-box --no-pager -n 15 2>/dev/null

    echo
    read -r -p "按回车返回菜单..."
}

# ------------------------------------------------------------
# 卸载
# ------------------------------------------------------------

uninstall_all() {

    clear

    echo "========================================"
    echo "             卸载 sing-box"
    echo "========================================"
    echo
    echo "此操作将："
    echo
    echo "1. 停止 sing-box"
    echo "2. 禁止开机启动"
    echo "3. 删除 sing-box 配置"
    echo "4. 删除快捷命令"
    echo
    echo "不会删除系统其他网络组件"
    echo

    read -r -p "确定卸载？输入 YES 确认: " CONFIRM

    clear

    if [ "$CONFIRM" != "YES" ]; then
        echo "已取消"
        sleep 1
        return
    fi

    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1

    rm -f "$CONFIG"
    rm -f "$BACKUP"
    rm -f "$LINK"
    rm -f "$SCRIPT"

    echo
    echo "配置和快捷命令已删除"
    echo
    echo "如需彻底删除 sing-box 软件包，请根据你的系统包管理器处理。"
    echo

    read -r -p "按回车返回..."
}

# ------------------------------------------------------------
# 主菜单
# ------------------------------------------------------------

while true; do

    clear

    echo "========================================"
    echo "          VPS 全局出口代理"
    echo "========================================"
    echo
    echo "1. 配置代理"
    echo "2. 开启全局代理"
    echo "3. 关闭全局代理"
    echo "4. 查看状态"
    echo "5. 安装 / 更新 sing-box"
    echo "6. 卸载配置"
    echo "0. 退出"
    echo
    echo "----------------------------------------"
    echo

    if command -v sing-box >/dev/null 2>&1; then
        echo "sing-box：已安装"
    else
        echo "sing-box：未安装"
    fi

    if systemctl is-active --quiet sing-box; then
        echo "代理状态：运行中"
    else
        echo "代理状态：已关闭"
    fi

    echo
    echo "----------------------------------------"
    echo

    read -r -p "请选择: " CHOICE

    clear

    case "$CHOICE" in

        1)
            apply_proxy
            ;;

        2)
            enable_proxy
            ;;

        3)
            disable_proxy
            ;;

        4)
            show_status
            ;;

        5)
            install_singbox
            ;;

        6)
            uninstall_all
            ;;

        0)
            clear
            exit 0
            ;;

        *)
            echo "无效选项"
            sleep 1
            ;;

    esac

done
