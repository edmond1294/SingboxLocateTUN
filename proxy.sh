#!/bin/bash

# ============================================================
# VPS 全局出口代理
# sing-box TUN
#
# 支持：
# 1. VLESS + WS + TLS
# 2. SOCKS5
# 3. VLESS + Reality
# ============================================================

set -u

CONFIG="/etc/sing-box/config.json"
BACKUP="/etc/sing-box/config.json.bak"

STATE_DIR="/etc/vps-out"
STATE_FILE="$STATE_DIR/type"

SCRIPT="/usr/local/bin/vps-out"
COMMAND="/usr/local/bin/out"

mkdir -p "$STATE_DIR"
mkdir -p /etc/sing-box

# ============================================================
# Root
# ============================================================

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行此脚本"
    exit 1
fi

# ============================================================
# 基础依赖
# ============================================================

install_basic() {

    if command -v apt-get >/dev/null 2>&1; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y >/dev/null 2>&1

        apt-get install -y \
            curl \
            ca-certificates \
            python3 \
            iproute2 \
            >/dev/null 2>&1

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y \
            curl \
            ca-certificates \
            python3 \
            iproute \
            >/dev/null 2>&1

    elif command -v yum >/dev/null 2>&1; then

        yum install -y \
            curl \
            ca-certificates \
            python3 \
            iproute \
            >/dev/null 2>&1

    elif command -v apk >/dev/null 2>&1; then

        apk add --no-cache \
            curl \
            ca-certificates \
            python3 \
            iproute2 \
            >/dev/null 2>&1

    fi
}

# ============================================================
# 快速安装 sing-box
# ============================================================

quick_install_singbox() {

    clear

    echo "========================================"
    echo "        快速安装 sing-box"
    echo "========================================"
    echo

    install_basic

    if command -v sing-box >/dev/null 2>&1; then

        echo "sing-box 已经安装"
        echo
        sing-box version 2>/dev/null | head -n 1
        echo
        read -r -p "按回车返回菜单..."
        clear
        return

    fi

    echo "正在安装 sing-box..."
    echo

    if curl -fsSL https://sing-box.app/install.sh | sh; then

        echo
        echo "sing-box 安装成功"
        echo

        sing-box version 2>/dev/null | head -n 1

    else

        echo
        echo "sing-box 安装失败"

    fi

    echo
    read -r -p "按回车返回菜单..."
    clear
}

# ============================================================
# 自动安装 sing-box
# ============================================================

install_singbox() {

    if command -v sing-box >/dev/null 2>&1; then
        return 0
    fi

    echo
    echo "检测到 sing-box 未安装"
    echo "正在自动安装..."
    echo

    install_basic

    if ! curl -fsSL https://sing-box.app/install.sh | sh; then
        echo
        echo "sing-box 安装失败"
        return 1
    fi

    if ! command -v sing-box >/dev/null 2>&1; then
        echo
        echo "sing-box 安装失败"
        return 1
    fi

    echo
    echo "sing-box 安装成功"
    echo

    return 0
}

# ============================================================
# 生成配置
# ============================================================

write_config() {

    local TYPE="$1"
    local NODE="$2"

    python3 - "$TYPE" "$NODE" "$CONFIG" <<'PY'

import sys
import json
import os

from urllib.parse import urlsplit, parse_qs, unquote

ptype = sys.argv[1]
node = sys.argv[2]
config_file = sys.argv[3]

u = urlsplit(node)

def qget(name, default=""):
    q = parse_qs(u.query)
    return unquote(q.get(name, [default])[0])

# ============================================================
# TUN
# ============================================================

tun = {
    "type": "tun",
    "tag": "tun-in",
    "interface_name": "singtun0",

    "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
    ],

    "auto_route": True,
    "strict_route": True,
    "stack": "system"
}

# ============================================================
# DNS
#
# 使用 sing-box 1.12+ 新格式
#
# 不使用旧版：
# "address": "8.8.8.8"
# ============================================================

dns = {
    "servers": [
        {
            "type": "udp",
            "tag": "dns-remote",
            "server": "1.1.1.1",
            "server_port": 53,
            "detour": "proxy"
        }
    ],
    "final": "dns-remote",
    "strategy": "prefer_ipv4"
}

# ============================================================
# VLESS + WS + TLS
# ============================================================

if ptype == "vless-ws-tls":

    uuid = unquote(u.username or "")
    server = u.hostname or ""
    port = u.port or 443

    security = qget("security")
    transport = qget("type")

    sni = qget("sni")
    fp = qget("fp")

    host = qget("host")
    path = qget("path")

    if not uuid:
        raise Exception("VLESS UUID 为空")

    if not server:
        raise Exception("服务器地址为空")

    outbound = {
        "type": "vless",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "uuid": uuid
    }

    # TLS

    if security == "tls":

        tls = {
            "enabled": True
        }

        if sni:
            tls["server_name"] = sni

        if fp:

            tls["utls"] = {
                "enabled": True,
                "fingerprint": fp
            }

        outbound["tls"] = tls

    # WebSocket

    if transport == "ws":

        ws = {
            "type": "ws"
        }

        if path:
            ws["path"] = path

        headers = {}

        if host:
            headers["Host"] = host

        if headers:
            ws["headers"] = headers

        outbound["transport"] = ws

# ============================================================
# SOCKS5
# ============================================================

elif ptype == "socks5":

    server = u.hostname or ""
    port = u.port or 1080

    username = unquote(u.username or "")
    password = unquote(u.password or "")

    if not server:
        raise Exception("SOCKS5 服务器地址为空")

    outbound = {
        "type": "socks",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "version": "5"
    }

    if username:
        outbound["username"] = username

    if password:
        outbound["password"] = password

# ============================================================
# VLESS + Reality
# ============================================================

elif ptype == "vless-reality":

    uuid = unquote(u.username or "")
    server = u.hostname or ""
    port = u.port or 443

    sni = qget("sni")
    fp = qget("fp")

    pbk = qget("pbk")
    sid = qget("sid")

    flow = qget("flow")

    if not uuid:
        raise Exception("VLESS UUID 为空")

    if not server:
        raise Exception("服务器地址为空")

    if not sni:
        raise Exception("Reality 缺少 sni")

    if not pbk:
        raise Exception("Reality 缺少 pbk")

    if not sid:
        raise Exception("Reality 缺少 sid")

    outbound = {
        "type": "vless",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "uuid": uuid
    }

    if flow:
        outbound["flow"] = flow

    tls = {
        "enabled": True,
        "server_name": sni,

        "reality": {
            "enabled": True,
            "public_key": pbk,
            "short_id": sid
        }
    }

    if fp:

        tls["utls"] = {
            "enabled": True,
            "fingerprint": fp
        }

    outbound["tls"] = tls

else:

    raise Exception("未知协议")

# ============================================================
# 最终配置
# ============================================================

config = {

    "log": {
        "level": "warn",
        "timestamp": True
    },

    "dns": dns,

    "inbounds": [
        tun
    ],

    "outbounds": [

        outbound,

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
        "rules": [
            {
                "protocol": "dns",
                "action": "hijack-dns"
            }
        ],
        "final": "proxy"
    }
}

os.makedirs(
    os.path.dirname(config_file),
    exist_ok=True
)

with open(
    config_file,
    "w",
    encoding="utf-8"
) as f:

    json.dump(
        config,
        f,
        ensure_ascii=False,
        indent=2
    )

print("配置生成成功")

PY
}

# ============================================================
# 检查配置
# ============================================================

check_config() {

    if ! sing-box check -c "$CONFIG"; then

        echo
        echo "========================================"
        echo "配置检查失败"
        echo "========================================"
        echo

        return 1
    fi

    return 0
}

# ============================================================
# 启动
# ============================================================

start_proxy() {

    systemctl daemon-reload >/dev/null 2>&1

    systemctl enable sing-box >/dev/null 2>&1

    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then

        echo
        echo "========================================"
        echo "全局代理已启动"
        echo "========================================"

        return 0

    else

        echo
        echo "启动失败"
        echo

        systemctl status sing-box --no-pager -l

        return 1
    fi
}

# ============================================================
# 停止
# ============================================================

stop_proxy() {

    systemctl stop sing-box >/dev/null 2>&1

    echo
    echo "全局代理已关闭"
}

# ============================================================
# 状态
# ============================================================

show_status() {

    clear

    echo "========================================"
    echo "          VPS 全局出口代理"
    echo "========================================"

    if systemctl is-active --quiet sing-box; then
        echo "状态：已开启"
    else
        echo "状态：已关闭"
    fi

    if [ -f "$STATE_FILE" ]; then
        echo "协议：$(cat "$STATE_FILE")"
    else
        echo "协议：未配置"
    fi

    echo

    if command -v sing-box >/dev/null 2>&1; then

        echo "sing-box：已安装"

        sing-box version 2>/dev/null | head -n 1

    else

        echo "sing-box：未安装"

    fi

    echo

    if [ -f "$CONFIG" ]; then

        if sing-box check -c "$CONFIG" >/dev/null 2>&1; then
            echo "配置：正常"
        else
            echo "配置：错误"
        fi

    else

        echo "配置：不存在"

    fi

    echo
    echo "========================================"

    echo
    read -r -p "按回车返回菜单..."

    clear
}

# ============================================================
# VLESS WS TLS
# ============================================================

config_vless_ws() {

    clear

    echo "========================================"
    echo "       VLESS + WS + TLS"
    echo "========================================"

    echo
    echo "请粘贴完整 VLESS 节点："
    echo

    read -r NODE

    if [ -z "$NODE" ]; then
        echo "没有输入节点"
        sleep 1
        clear
        return
    fi

    case "$NODE" in

        vless://*)
            ;;

        *)
            echo "节点格式错误"
            sleep 1
            clear
            return
            ;;

    esac

    if ! install_singbox; then

        read -r -p "按回车返回菜单..."
        clear
        return

    fi

    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP"
    fi

    if ! write_config "vless-ws-tls" "$NODE"; then

        echo
        echo "配置生成失败"

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        read -r -p "按回车返回菜单..."
        clear

        return
    fi

    if ! check_config; then

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        read -r -p "按回车返回菜单..."
        clear

        return
    fi

    echo "vless-ws-tls" > "$STATE_FILE"

    start_proxy

    echo
    read -r -p "按回车返回菜单..."

    clear
}

# ============================================================
# SOCKS5
# ============================================================

config_socks5() {

    clear

    echo "========================================"
    echo "             SOCKS5"
    echo "========================================"

    echo
    echo "请粘贴完整 SOCKS5 节点："
    echo
    echo "例如："
    echo "socks5://user:password@server:1080"
    echo

    read -r NODE

    if [ -z "$NODE" ]; then

        echo "没有输入节点"

        sleep 1
        clear

        return
    fi

    case "$NODE" in

        socks5://*)
            ;;

        socks://*)
            ;;

        *)
            echo "节点格式错误"
            sleep 1
            clear
            return
            ;;

    esac

    if ! install_singbox; then

        read -r -p "按回车返回菜单..."
        clear

        return
    fi

    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP"
    fi

    if ! write_config "socks5" "$NODE"; then

        echo
        echo "配置生成失败"

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        read -r -p "按回车返回菜单..."
        clear

        return
    fi

    if ! check_config; then

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        read -r -p "按回车返回菜单..."
        clear

        return
    fi

    echo "socks5" > "$STATE_FILE"

    start_proxy

    echo
    read -r -p "按回车返回菜单..."

    clear
}

# ============================================================
# VLESS Reality
# ============================================================

config_reality() {

    clear

    echo "========================================"
    echo "          VLESS + Reality"
    echo "========================================"

    echo
    echo "请粘贴完整 VLESS Reality 节点："
    echo

    read -r NODE

    if [ -z "$NODE" ]; then

        echo "没有输入节点"

        sleep 1
        clear

        return
    fi

    case "$NODE" in

        vless://*)
            ;;

        *)
            echo "节点格式错误"
            sleep 1
            clear
            return
            ;;

    esac

    if ! install_singbox; then

        read -r -p "按回车返回菜单..."
        clear

        return
    fi

    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP"
    fi

    if ! write_config "vless-reality" "$NODE"; then

        echo
        echo "配置生成失败"

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        read -r -p "按回车返回菜单..."
        clear

        return
    fi

    if ! check_config; then

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        read -r -p "按回车返回菜单..."
        clear

        return
    fi

    echo "vless-reality" > "$STATE_FILE"

    start_proxy

    echo
    read -r -p "按回车返回菜单..."

    clear
}

# ============================================================
# 关闭
# ============================================================

disable_proxy() {

    clear

    stop_proxy

    rm -f "$STATE_FILE"

    echo
    read -r -p "按回车返回菜单..."

    clear
}

# ============================================================
# 配置选择
# ============================================================

config_menu() {

    clear

    echo "========================================"
    echo "             选择代理类型"
    echo "========================================"

    echo
    echo "1. VLESS + WS + TLS"
    echo "2. SOCKS5"
    echo "3. VLESS + Reality"
    echo "0. 返回"
    echo

    echo -n "请选择："

    read -r TYPE

    # 选择后立即 clear

    clear

    case "$TYPE" in

        1)
            config_vless_ws
            ;;

        2)
            config_socks5
            ;;

        3)
            config_reality
            ;;

        0)
            clear
            ;;

        *)
            echo "无效选择"
            sleep 1
            clear
            ;;

    esac
}

# ============================================================
# 主菜单
# ============================================================

menu() {

    while true; do

        clear

        echo "========================================"
        echo "          VPS 全局出口代理"
        echo "========================================"

        if systemctl is-active --quiet sing-box 2>/dev/null; then

            echo "当前状态：已开启"

        else

            echo "当前状态：已关闭"

        fi

        if [ -f "$STATE_FILE" ]; then

            echo "当前协议：$(cat "$STATE_FILE")"

        else

            echo "当前协议：未配置"

        fi

        echo "========================================"

        echo
        echo "1. 配置"
        echo "2. 关闭全局代理"
        echo "3. 查看状态"
        echo "4. 快速安装 sing-box"
        echo "0. 退出"
        echo

        echo -n "请选择："

        read -r CHOICE

        # 主菜单选择后 clear

        clear

        case "$CHOICE" in

            1)

                config_menu
                ;;

            2)

                disable_proxy
                ;;

            3)

                show_status
                ;;

            4)

                quick_install_singbox
                ;;

            0)

                clear
                exit 0
                ;;

            *)

                echo "无效选择"
                sleep 1
                clear
                ;;

        esac

    done
}

# ============================================================
# 命令模式
# ============================================================

case "${1:-}" in

    on)

        if [ ! -f "$CONFIG" ]; then

            echo "还没有配置节点"
            echo "请执行：out"

            exit 1
        fi

        install_singbox || exit 1

        check_config || exit 1

        start_proxy

        ;;

    off)

        disable_proxy
        ;;

    restart)

        systemctl restart sing-box

        ;;

    status)

        show_status
        ;;

    check)

        check_config
        ;;

    logs)

        journalctl -u sing-box --no-pager -n 100

        ;;

    install)

        quick_install_singbox
        ;;

    *)

        menu
        ;;

esac
