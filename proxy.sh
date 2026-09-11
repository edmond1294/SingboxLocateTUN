#!/bin/bash

# ============================================================
# VPS 全局出口代理
# sing-box TUN
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

# ------------------------------------------------------------
# Root
# ------------------------------------------------------------

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行此脚本"
    exit 1
fi

# ------------------------------------------------------------
# 基础命令
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# 安装 sing-box
# ------------------------------------------------------------

install_singbox() {

    if command -v sing-box >/dev/null 2>&1; then
        return
    fi

    echo "正在安装 sing-box..."

    curl -fsSL https://sing-box.app/install.sh | sh

    if ! command -v sing-box >/dev/null 2>&1; then
        echo "sing-box 安装失败"
        exit 1
    fi
}

# ------------------------------------------------------------
# Python JSON 工具
# ------------------------------------------------------------

python_check() {

    if ! command -v python3 >/dev/null 2>&1; then
        echo "系统没有 Python3"
        exit 1
    fi
}

# ------------------------------------------------------------
# URL 解析
# ------------------------------------------------------------

parse_url() {

    local URL="$1"

    python3 - "$URL" <<'PY'
import sys
from urllib.parse import urlsplit, parse_qs, unquote

url = sys.argv[1]

try:
    u = urlsplit(url)

    scheme = u.scheme.lower()

    if scheme in ("vless",):

        uuid = unquote(u.username or "")
        server = u.hostname or ""
        port = u.port or 443

        q = parse_qs(u.query)

        def get(k, default=""):
            return unquote(q.get(k, [default])[0])

        security = get("security")
        transport = get("type")
        sni = get("sni")
        fp = get("fp")
        host = get("host")
        path = get("path")
        flow = get("flow")
        pbk = get("pbk")
        sid = get("sid")
        alpn = get("alpn")

        print("SCHEME=" + scheme)
        print("UUID=" + uuid)
        print("SERVER=" + server)
        print("PORT=" + str(port))
        print("SECURITY=" + security)
        print("TYPE=" + transport)
        print("SNI=" + sni)
        print("FP=" + fp)
        print("HOST=" + host)
        print("PATH=" + path)
        print("FLOW=" + flow)
        print("PBK=" + pbk)
        print("SID=" + sid)
        print("ALPN=" + alpn)

    elif scheme in ("socks5", "socks"):

        username = unquote(u.username or "")
        password = unquote(u.password or "")
        server = u.hostname or ""
        port = u.port or 1080

        print("SCHEME=socks5")
        print("USERNAME=" + username)
        print("PASSWORD=" + password)
        print("SERVER=" + server)
        print("PORT=" + str(port))

    else:

        echo=""

        print("SCHEME=" + scheme)

except Exception as e:

    print("ERROR=" + str(e))
PY
}

# ------------------------------------------------------------
# 生成 TUN 配置
# ------------------------------------------------------------

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
# 基础 TUN
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
# Route
# ============================================================

route = {
    "auto_detect_interface": True,
    "final": "proxy"
}

# ============================================================
# DNS
#
# 重点：
# 这里绝对不使用旧版：
#
# "address": "8.8.8.8"
#
# 而是新版：
#
# "type": "udp",
# "server": "8.8.8.8"
#
# 解决 sing-box 1.12/1.14 DNS legacy 错误。
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
# VLESS
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
# VLESS Reality
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

    "route": route
}

# 写入
os.makedirs(os.path.dirname(config_file), exist_ok=True)

with open(config_file, "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)

print("配置生成成功")

PY
}

# ------------------------------------------------------------
# 检查配置
# ------------------------------------------------------------

check_config() {

    if ! sing-box check -c "$CONFIG"; then

        echo
        echo "配置检查失败"
        echo
        echo "当前配置："
        echo "----------------------------------------"
        cat "$CONFIG"
        echo "----------------------------------------"

        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# 启动
# ------------------------------------------------------------

start_proxy() {

    systemctl daemon-reload >/dev/null 2>&1

    systemctl enable sing-box >/dev/null 2>&1

    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then

        echo
        echo "全局代理已启动"
        echo "状态：运行中"

        return 0

    else

        echo
        echo "启动失败"
        echo
        systemctl status sing-box --no-pager -l

        return 1
    fi
}

# ------------------------------------------------------------
# 停止
# ------------------------------------------------------------

stop_proxy() {

    systemctl stop sing-box >/dev/null 2>&1

    echo
    echo "全局代理已关闭"
}

# ------------------------------------------------------------
# 状态
# ------------------------------------------------------------

show_status() {

    echo
    echo "========================================"
    echo "VPS 全局出口代理"
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

    if command -v sing-box >/dev/null 2>&1; then
        echo "sing-box：$(sing-box version 2>/dev/null | head -n 1)"
    else
        echo "sing-box：未安装"
    fi

    echo

    if [ -f "$CONFIG" ]; then
        echo "配置检查："

        if sing-box check -c "$CONFIG" >/dev/null 2>&1; then
            echo "正常"
        else
            echo "失败"
        fi
    else
        echo "配置文件：不存在"
    fi

    echo "========================================"
}

# ------------------------------------------------------------
# 配置 VLESS WS TLS
# ------------------------------------------------------------

config_vless_ws() {

    echo
    echo "========================================"
    echo "配置 VLESS + WS + TLS"
    echo "========================================"
    echo
    echo "请粘贴完整 VLESS 节点："
    echo

    read -r NODE

    if [ -z "$NODE" ]; then
        echo "没有输入节点"
        return
    fi

    case "$NODE" in
        vless://*)
            ;;
        *)
            echo "节点格式错误，需要 vless:// 开头"
            return
            ;;
    esac

    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP"
    fi

    if ! write_config "vless-ws-tls" "$NODE"; then
        echo "配置生成失败"
        return
    fi

    if ! check_config; then
        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"
        return
    fi

    echo "vless-ws-tls" > "$STATE_FILE"

    echo
    echo "配置成功"
    echo

    start_proxy
}

# ------------------------------------------------------------
# 配置 SOCKS5
# ------------------------------------------------------------

config_socks5() {

    echo
    echo "========================================"
    echo "配置 SOCKS5"
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
        return
    fi

    case "$NODE" in
        socks5://*|socks://*)
            ;;
        *)
            echo "节点格式错误，需要 socks5:// 或 socks:// 开头"
            return
            ;;
    esac

    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP"
    fi

    if ! write_config "socks5" "$NODE"; then
        echo "配置生成失败"
        return
    fi

    if ! check_config; then
        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"
        return
    fi

    echo "socks5" > "$STATE_FILE"

    echo
    echo "配置成功"
    echo

    start_proxy
}

# ------------------------------------------------------------
# 配置 VLESS Reality
# ------------------------------------------------------------

config_reality() {

    echo
    echo "========================================"
    echo "配置 VLESS + Reality"
    echo "========================================"
    echo
    echo "请粘贴完整 VLESS Reality 节点："
    echo

    read -r NODE

    if [ -z "$NODE" ]; then
        echo "没有输入节点"
        return
    fi

    case "$NODE" in
        vless://*)
            ;;
        *)
            echo "节点格式错误，需要 vless:// 开头"
            return
            ;;
    esac

    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP"
    fi

    if ! write_config "vless-reality" "$NODE"; then
        echo "配置生成失败"
        return
    fi

    if ! check_config; then
        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"
        return
    fi

    echo "vless-reality" > "$STATE_FILE"

    echo
    echo "配置成功"
    echo

    start_proxy
}

# ------------------------------------------------------------
# 关闭
# ------------------------------------------------------------

disable_proxy() {

    stop_proxy

    rm -f "$STATE_FILE"
}

# ------------------------------------------------------------
# 菜单
# ------------------------------------------------------------

menu() {

    while true; do

        clear

        echo "========================================"
        echo "       VPS 全局出口代理"
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
        echo "0. 退出"
        echo
        echo -n "请选择："

        read -r CHOICE

        case "$CHOICE" in

            1)

                echo
                echo "========================================"
                echo "请选择代理类型"
                echo "========================================"
                echo
                echo "1. VLESS + WS + TLS"
                echo "2. SOCKS5"
                echo "3. VLESS + Reality"
                echo "0. 返回"
                echo
                echo -n "请选择："

                read -r TYPE

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
                        ;;
                    *)
                        echo "无效选择"
                        sleep 1
                        ;;
                esac

                ;;

            2)

                disable_proxy
                sleep 1
                ;;

            3)

                show_status
                echo
                read -r -p "按回车返回..."
                ;;

            0)

                exit 0
                ;;

            *)

                echo "无效选择"
                sleep 1
                ;;

        esac

    done
}

# ------------------------------------------------------------
# 命令行参数
# ------------------------------------------------------------

case "${1:-}" in

    on)

        if [ ! -f "$CONFIG" ]; then
            echo "还没有配置节点，请执行：out"
            exit 1
        fi

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

    *)

        menu
        ;;

esac
