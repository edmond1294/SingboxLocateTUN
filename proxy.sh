#!/bin/bash

# ============================================================
# VPS 全局出口代理
# sing-box
#
# 支持：
# 1. VLESS + WS + TLS（Argo）
# 2. SOCKS5
# 3. VLESS + Reality
#
# 特性：
# - 自动安装 sing-box
# - 自动解析分享链接
# - TUN 全局代理
# - VPS 自身出口
# - 自动检查配置
# - 自动启动服务
# - 选项执行完成后自动 clear
# - out 快捷命令
# ============================================================

set -u

CONFIG="/etc/sing-box/config.json"
BACKUP="/etc/sing-box/config.json.bak"

DATA_DIR="/etc/vps-out"
TYPE_FILE="$DATA_DIR/type"

BIN="/usr/local/bin/vps-out"
SHORT_BIN="/usr/local/bin/out"

SERVICE="sing-box"

# ============================================================
# Root
# ============================================================

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行"
    exit 1
fi

# ============================================================
# 创建目录
# ============================================================

mkdir -p /etc/sing-box
mkdir -p "$DATA_DIR"

# ============================================================
# 安装基础组件
# ============================================================

install_basic() {

    echo
    echo "正在检查系统组件..."

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

install_singbox() {

    clear

    echo "========================================"
    echo "        快速安装 sing-box"
    echo "========================================"
    echo

    if command -v sing-box >/dev/null 2>&1; then

        echo "sing-box 已安装"
        echo
        sing-box version 2>/dev/null | head -n 1

        echo
        read -r -p "按回车返回菜单..."
        clear
        return

    fi

    echo "正在安装 sing-box..."
    echo

    curl -fsSL https://sing-box.app/install.sh | sh

    echo

    if command -v sing-box >/dev/null 2>&1; then

        echo "sing-box 安装成功"
        echo
        sing-box version 2>/dev/null | head -n 1

    else

        echo "sing-box 安装失败"

    fi

    echo
    read -r -p "按回车返回菜单..."
    clear
}

# ============================================================
# 检查 / 自动安装 sing-box
# ============================================================

ensure_singbox() {

    if command -v sing-box >/dev/null 2>&1; then
        return 0
    fi

    echo
    echo "检测到 sing-box 未安装"
    echo "正在自动安装..."
    echo

    curl -fsSL https://sing-box.app/install.sh | sh

    if ! command -v sing-box >/dev/null 2>&1; then

        echo
        echo "sing-box 安装失败"
        echo "请检查 VPS 网络"
        echo

        return 1
    fi

    echo
    echo "sing-box 安装成功"
    echo

    return 0
}

# ============================================================
# 写入 systemd
# ============================================================

setup_service() {

    mkdir -p /etc/systemd/system/sing-box.service.d

    cat > /etc/systemd/system/sing-box.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=3
EOF

    systemctl daemon-reload >/dev/null 2>&1
}

# ============================================================
# 解析节点
# ============================================================

parse_node() {

    local NODE="$1"

    python3 - "$NODE" <<'PY'
import sys
from urllib.parse import urlsplit, parse_qs, unquote

url = sys.argv[1]

try:

    u = urlsplit(url)

    scheme = u.scheme.lower()

    if scheme == "vless":

        q = parse_qs(u.query)

        def get(name, default=""):
            return unquote(q.get(name, [default])[0])

        uuid = unquote(u.username or "")
        server = u.hostname or ""
        port = u.port or 443

        print("SCHEME=vless")
        print("UUID=" + uuid)
        print("SERVER=" + server)
        print("PORT=" + str(port))
        print("SECURITY=" + get("security"))
        print("TYPE=" + get("type"))
        print("SNI=" + get("sni"))
        print("FP=" + get("fp"))
        print("HOST=" + get("host"))
        print("PATH=" + get("path"))
        print("FLOW=" + get("flow"))
        print("PBK=" + get("pbk"))
        print("SID=" + get("sid"))
        print("ALPN=" + get("alpn"))

    elif scheme in ("socks5", "socks"):

        print("SCHEME=socks5")
        print("USERNAME=" + unquote(u.username or ""))
        print("PASSWORD=" + unquote(u.password or ""))
        print("SERVER=" + (u.hostname or ""))
        print("PORT=" + str(u.port or 1080))

    else:

        print("ERROR=不支持的协议")

except Exception as e:

    print("ERROR=" + str(e))
PY
}

# ============================================================
# 生成配置
# ============================================================

generate_config() {

    local MODE="$1"
    local NODE="$2"

    python3 - "$MODE" "$NODE" "$CONFIG" <<'PY'

import sys
import json
import os

from urllib.parse import urlsplit
from urllib.parse import parse_qs
from urllib.parse import unquote

mode = sys.argv[1]
node = sys.argv[2]
config_file = sys.argv[3]

u = urlsplit(node)

q = parse_qs(u.query)

def get(name, default=""):
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

    "stack": "system",

    "mtu": 1500
}

# ============================================================
# DNS
#
# 新版 sing-box DNS 格式
#
# 不使用旧：
# "address": "8.8.8.8"
#
# 使用：
# "type": "udp"
# "server": "1.1.1.1"
# ============================================================

dns = {
    "servers": [
        {
            "type": "udp",
            "tag": "dns-direct",
            "server": "1.1.1.1",
            "server_port": 53
        }
    ],

    "final": "dns-direct",

    "strategy": "prefer_ipv4"
}

# ============================================================
# OUTBOUND
# ============================================================

if mode == "vless-ws-tls":

    uuid = unquote(u.username or "")
    server = u.hostname or ""
    port = u.port or 443

    if not uuid:
        raise Exception("VLESS UUID 为空")

    if not server:
        raise Exception("VLESS 服务器为空")

    outbound = {
        "type": "vless",

        "tag": "proxy",

        "server": server,

        "server_port": port,

        "uuid": uuid
    }

    # --------------------------------------------------------
    # TLS
    # --------------------------------------------------------

    if get("security") == "tls":

        tls = {
            "enabled": True
        }

        sni = get("sni")

        if sni:
            tls["server_name"] = sni

        fp = get("fp")

        if fp:
            tls["utls"] = {
                "enabled": True,
                "fingerprint": fp
            }

        outbound["tls"] = tls

    # --------------------------------------------------------
    # WebSocket
    # --------------------------------------------------------

    if get("type") == "ws":

        ws = {
            "type": "ws"
        }

        path = get("path")

        if path:
            ws["path"] = path

        host = get("host")

        if host:
            ws["headers"] = {
                "Host": host
            }

        outbound["transport"] = ws


# ============================================================
# SOCKS5
# ============================================================

elif mode == "socks5":

    server = u.hostname or ""
    port = u.port or 1080

    username = unquote(u.username or "")
    password = unquote(u.password or "")

    if not server:
        raise Exception("SOCKS5 服务器为空")

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

elif mode == "vless-reality":

    uuid = unquote(u.username or "")
    server = u.hostname or ""
    port = u.port or 443

    sni = get("sni")
    fp = get("fp")
    pbk = get("pbk")
    sid = get("sid")
    flow = get("flow")

    if not uuid:
        raise Exception("VLESS UUID 为空")

    if not server:
        raise Exception("Reality 服务器为空")

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

    raise Exception("未知代理类型")


# ============================================================
# 完整配置
# ============================================================

config = {

    "log": {
        "disabled": False,
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

os.makedirs(os.path.dirname(config_file), exist_ok=True)

with open(config_file, "w", encoding="utf-8") as f:

    json.dump(
        config,
        f,
        ensure_ascii=False,
        indent=2
    )

print("OK")

PY
}

# ============================================================
# 检查配置
# ============================================================

check_config() {

    sing-box check -c "$CONFIG"
}

# ============================================================
# 启动
# ============================================================

start_proxy() {

    setup_service

    systemctl enable "$SERVICE" >/dev/null 2>&1

    systemctl restart "$SERVICE"

    sleep 2

    if systemctl is-active --quiet "$SERVICE"; then

        return 0

    fi

    return 1
}

# ============================================================
# 停止
# ============================================================

stop_proxy() {

    systemctl stop "$SERVICE" >/dev/null 2>&1
}

# ============================================================
# 配置 VLESS WS TLS
# ============================================================

config_vless_ws() {

    clear

    echo "========================================"
    echo "     VLESS + WS + TLS（Argo）"
    echo "========================================"
    echo
    echo "请粘贴完整 VLESS 链接："
    echo

    read -r NODE

    if [ -z "$NODE" ]; then

        echo
        echo "没有输入节点"
        sleep 2
        clear
        return

    fi

    case "$NODE" in

        vless://*)
            ;;

        *)
            echo
            echo "格式错误"
            echo "必须以 vless:// 开头"
            sleep 2
            clear
            return
            ;;

    esac

    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP"
    fi

    echo
    echo "正在解析节点..."

    if ! generate_config "vless-ws-tls" "$NODE"; then

        echo
        echo "节点解析失败"

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        sleep 2
        clear
        return

    fi

    echo "正在检查 sing-box 配置..."

    if ! check_config >/dev/null 2>&1; then

        echo
        echo "配置检查失败"
        echo

        sing-box check -c "$CONFIG"

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        echo
        read -r -p "按回车返回..."
        clear
        return

    fi

    echo "配置检查通过"
    echo "正在启动..."

    echo "vless-ws-tls" > "$TYPE_FILE"

    if start_proxy; then

        echo
        echo "配置成功"
        echo "全局出口已开启"

    else

        echo
        echo "启动失败"
        systemctl status sing-box --no-pager -l

    fi

    echo
    read -r -p "按回车返回菜单..."
    clear
}

# ============================================================
# 配置 SOCKS5
# ============================================================

config_socks5() {

    clear

    echo "========================================"
    echo "              SOCKS5"
    echo "========================================"
    echo
    echo "请粘贴完整 SOCKS5 链接："
    echo
    echo "例如："
    echo "socks5://user:password@example.com:1080"
    echo

    read -r NODE

    if [ -z "$NODE" ]; then

        echo
        echo "没有输入节点"
        sleep 2
        clear
        return

    fi

    case "$NODE" in

        socks5://*)
            ;;

        socks://*)
            ;;

        *)
            echo
            echo "格式错误"
            echo "必须以 socks5:// 或 socks:// 开头"
            sleep 2
            clear
            return
            ;;

    esac

    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP"
    fi

    echo
    echo "正在解析节点..."

    if ! generate_config "socks5" "$NODE"; then

        echo
        echo "节点解析失败"

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        sleep 2
        clear
        return

    fi

    echo "正在检查 sing-box 配置..."

    if ! check_config >/dev/null 2>&1; then

        echo
        echo "配置检查失败"
        echo

        sing-box check -c "$CONFIG"

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        echo
        read -r -p "按回车返回..."
        clear
        return

    fi

    echo "配置检查通过"
    echo "正在启动..."

    echo "socks5" > "$TYPE_FILE"

    if start_proxy; then

        echo
        echo "配置成功"
        echo "全局出口已开启"

    else

        echo
        echo "启动失败"
        systemctl status sing-box --no-pager -l

    fi

    echo
    read -r -p "按回车返回菜单..."
    clear
}

# ============================================================
# 配置 Reality
# ============================================================

config_reality() {

    clear

    echo "========================================"
    echo "          VLESS + Reality"
    echo "========================================"
    echo
    echo "请粘贴完整 VLESS Reality 链接："
    echo

    read -r NODE

    if [ -z "$NODE" ]; then

        echo
        echo "没有输入节点"
        sleep 2
        clear
        return

    fi

    case "$NODE" in

        vless://*)
            ;;

        *)
            echo
            echo "格式错误"
            echo "必须以 vless:// 开头"
            sleep 2
            clear
            return
            ;;

    esac

    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP"
    fi

    echo
    echo "正在解析节点..."

    if ! generate_config "vless-reality" "$NODE"; then

        echo
        echo "节点解析失败"

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        sleep 2
        clear
        return

    fi

    echo "正在检查 sing-box 配置..."

    if ! check_config >/dev/null 2>&1; then

        echo
        echo "配置检查失败"
        echo

        sing-box check -c "$CONFIG"

        [ -f "$BACKUP" ] && cp "$BACKUP" "$CONFIG"

        echo
        read -r -p "按回车返回..."
        clear
        return

    fi

    echo "配置检查通过"
    echo "正在启动..."

    echo "vless-reality" > "$TYPE_FILE"

    if start_proxy; then

        echo
        echo "配置成功"
        echo "全局出口已开启"

    else

        echo
        echo "启动失败"
        systemctl status sing-box --no-pager -l

    fi

    echo
    read -r -p "按回车返回菜单..."
    clear
}

# ============================================================
# 配置菜单
# ============================================================

config_menu() {

    clear

    echo "========================================"
    echo "             选择代理类型"
    echo "========================================"
    echo
    echo "1. VLESS + WS + TLS（Argo）"
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
            clear
            ;;

        *)
            echo
            echo "无效选择"
            sleep 1
            clear
            ;;

    esac
}

# ============================================================
# 关闭代理
# ============================================================

disable_proxy() {

    clear

    echo "========================================"
    echo "           关闭全局代理"
    echo "========================================"
    echo

    stop_proxy

    rm -f "$TYPE_FILE"

    echo "全局代理已关闭"

    echo
    read -r -p "按回车返回菜单..."

    clear
}

# ============================================================
# 状态
# ============================================================

show_status() {

    clear

    echo "========================================"
    echo "              当前状态"
    echo "========================================"
    echo

    if systemctl is-active --quiet sing-box; then

        echo "状态：运行中"

    else

        echo "状态：已停止"

    fi

    if [ -f "$TYPE_FILE" ]; then

        echo "协议：$(cat "$TYPE_FILE")"

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

    echo "服务：$SERVICE"

    echo

    read -r -p "按回车返回菜单..."

    clear
}

# ============================================================
# 日志
# ============================================================

show_logs() {

    journalctl -u sing-box -n 100 --no-pager
}

# ============================================================
# 快捷命令
# ============================================================

install_shortcut() {

    cp "$0" "$BIN" 2>/dev/null || true

    chmod +x "$BIN" 2>/dev/null || true

    cat > "$SHORT_BIN" <<EOF
#!/bin/bash
exec "$BIN" "\$@"
EOF

    chmod +x "$SHORT_BIN"

}

# ============================================================
# 主菜单
# ============================================================

main_menu() {

    while true; do

        clear

        echo "========================================"
        echo "          VPS 全局出口代理"
        echo "========================================"
        echo

        if systemctl is-active --quiet sing-box 2>/dev/null; then

            echo "当前状态：已开启"

        else

            echo "当前状态：已关闭"

        fi

        if [ -f "$TYPE_FILE" ]; then

            echo "当前协议：$(cat "$TYPE_FILE")"

        else

            echo "当前协议：未配置"

        fi

        echo
        echo "========================================"
        echo
        echo "1. 配置"
        echo "2. 关闭全局代理"
        echo "3. 查看状态"
        echo "4. 快速安装 sing-box"
        echo "5. 查看日志"
        echo "0. 退出"
        echo
        echo -n "请选择："

        read -r CHOICE

        case "$CHOICE" in

            1)

                ensure_singbox || {
                    echo
                    read -r -p "按回车返回..."
                    clear
                    continue
                }

                config_menu

                ;;

            2)

                disable_proxy

                ;;

            3)

                show_status

                ;;

            4)

                install_singbox

                ;;

            5)

                clear

                show_logs

                echo
                read -r -p "按回车返回菜单..."

                clear

                ;;

            0)

                clear
                exit 0

                ;;

            *)

                echo
                echo "无效选择"
                sleep 1
                clear

                ;;

        esac

    done
}

# ============================================================
# 参数模式
# ============================================================

case "${1:-}" in

    on)

        ensure_singbox || exit 1

        if [ ! -f "$CONFIG" ]; then

            echo "还没有配置节点"
            echo "请执行：out"

            exit 1

        fi

        check_config || exit 1

        if start_proxy; then

            echo "全局代理已开启"

        else

            echo "启动失败"

        fi

        ;;

    off)

        stop_proxy

        rm -f "$TYPE_FILE"

        echo "全局代理已关闭"

        ;;

    restart)

        systemctl restart sing-box

        echo "sing-box 已重启"

        ;;

    status)

        show_status

        ;;

    check)

        check_config

        ;;

    logs)

        show_logs

        ;;

    install)

        install_basic

        install_singbox

        ;;

    *)

        install_basic

        ensure_singbox || exit 1

        install_shortcut

        main_menu

        ;;

esac
