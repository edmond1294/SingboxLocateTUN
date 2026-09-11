#!/bin/bash

CONFIG="/etc/sing-box/config.json"
BACKUP="/etc/sing-box/config.json.bak"
INSTALL_PATH="/usr/local/bin/vps-out"
OUT_PATH="/usr/local/bin/out"

SCRIPT_NAME="VPS 全局出口代理"

RED=""
GREEN=""
YELLOW=""
BLUE=""
RESET=""

if [ -t 1 ]; then
    RED="\033[31m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    BLUE="\033[36m"
    RESET="\033[0m"
fi

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 用户运行此脚本"
    exit 1
fi

mkdir -p /etc/sing-box
mkdir -p /etc/vps-out

clear

echo "======================================"
echo "        VPS 全局出口代理"
echo "======================================"
echo ""

install_basic() {
    echo "正在检查系统依赖..."

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl ca-certificates python3 iproute2 >/dev/null 2>&1

    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates python3 iproute >/dev/null 2>&1

    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates python3 iproute >/dev/null 2>&1

    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates python3 iproute2 >/dev/null 2>&1

    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl ca-certificates python iproute2 >/dev/null 2>&1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Python3 安装失败"
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "curl 安装失败"
        return 1
    fi

    return 0
}

install_singbox() {
    clear

    echo "======================================"
    echo "        安装 / 更新 sing-box"
    echo "======================================"
    echo ""

    install_basic || {
        echo ""
        echo "依赖安装失败"
        read -r -p "按回车返回..."
        return 1
    }

    echo "正在安装最新版 sing-box..."
    echo ""

    curl -fsSL https://sing-box.app/install.sh | sh

    if command -v sing-box >/dev/null 2>&1; then
        echo ""
        echo "sing-box 安装成功"
        echo ""
        sing-box version
    else
        echo ""
        echo "sing-box 安装失败"
        read -r -p "按回车返回..."
        return 1
    fi

    systemctl daemon-reload >/dev/null 2>&1

    if systemctl list-unit-files 2>/dev/null | grep -q "^sing-box.service"; then
        systemctl enable sing-box >/dev/null 2>&1
    fi

    echo ""
    read -r -p "按回车返回..."
}

check_singbox() {
    if command -v sing-box >/dev/null 2>&1; then
        return 0
    fi

    clear

    echo "系统中没有 sing-box"
    echo ""
    echo "正在自动安装..."
    echo ""

    install_basic || {
        echo "依赖安装失败"
        exit 1
    }

    curl -fsSL https://sing-box.app/install.sh | sh

    if ! command -v sing-box >/dev/null 2>&1; then
        echo ""
        echo "sing-box 安装失败"
        exit 1
    fi

    systemctl daemon-reload >/dev/null 2>&1
}

get_ssh_client_ip() {
    SSH_IP=""

    if [ -n "${SSH_CLIENT:-}" ]; then
        SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    fi

    if [ -z "$SSH_IP" ] && [ -n "${SSH_CONNECTION:-}" ]; then
        SSH_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    fi
}

build_exclude_json() {
    get_ssh_client_ip

    EXCLUDE='
        "192.168.0.0/16",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "224.0.0.0/4",
        "::1/128",
        "fc00::/7",
        "fe80::/10",
        "ff00::/8"
    '

    if [ -n "$SSH_IP" ]; then
        EXCLUDE="${EXCLUDE},"
        EXCLUDE="${EXCLUDE}
        \"${SSH_IP}/32\""
    fi
}

parse_vless() {
    NODE="$1"
    MODE="$2"

    python3 - "$NODE" "$MODE" <<'PY'
import sys
import json
from urllib.parse import urlsplit, parse_qs, unquote

url = sys.argv[1]
mode = sys.argv[2]

try:
    u = urlsplit(url)

    if u.scheme.lower() != "vless":
        raise Exception("不是 VLESS 链接")

    if not u.hostname:
        raise Exception("无法解析服务器地址")

    uuid = u.username
    server = u.hostname
    port = u.port or 443

    q = parse_qs(u.query)

    def get(name, default=""):
        value = q.get(name, [default])[0]
        return unquote(value)

    security = get("security", "")
    transport_type = get("type", "")

    obj = {
        "type": "vless",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "uuid": uuid
    }

    if not uuid:
        raise Exception("无法解析 UUID")

    # ---------------------------------
    # VLESS + WS + TLS
    # ---------------------------------
    if mode == "ws":

        if security.lower() != "tls":
            raise Exception("该链接不是 TLS 模式")

        if transport_type.lower() != "ws":
            raise Exception("该链接不是 WebSocket")

        sni = get("sni", "")
        fp = get("fp", "")
        host = get("host", "")
        path = get("path", "/")

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

        obj["tls"] = tls

        transport = {
            "type": "ws",
            "path": path
        }

        if host:
            transport["headers"] = {
                "Host": host
            }

        obj["transport"] = transport

    # ---------------------------------
    # VLESS + Reality
    # ---------------------------------
    elif mode == "reality":

        if security.lower() != "reality":
            raise Exception("该链接不是 Reality")

        sni = get("sni", "")
        fp = get("fp", "chrome")
        pbk = get("pbk", "")
        sid = get("sid", "")
        flow = get("flow", "")

        if not sni:
            raise Exception("Reality 缺少 sni")

        if not pbk:
            raise Exception("Reality 缺少 pbk")

        tls = {
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

        obj["tls"] = tls

        if flow:
            obj["flow"] = flow

        if transport_type and transport_type.lower() != "tcp":
            if transport_type.lower() == "grpc":
                service_name = get("serviceName", "")
                obj["transport"] = {
                    "type": "grpc",
                    "service_name": service_name
                }

    else:
        raise Exception("未知 VLESS 模式")

    print(json.dumps(obj, ensure_ascii=False, indent=2))

except Exception as e:
    print("ERROR:" + str(e))
    sys.exit(1)
PY
}

parse_socks() {
    NODE="$1"

    python3 - "$NODE" <<'PY'
import sys
import json
from urllib.parse import urlsplit, unquote

url = sys.argv[1]

try:
    u = urlsplit(url)

    if u.scheme.lower() not in ("socks", "socks5"):
        raise Exception("不是 SOCKS 链接")

    if not u.hostname:
        raise Exception("无法解析服务器地址")

    obj = {
        "type": "socks",
        "tag": "proxy",
        "server": u.hostname,
        "server_port": u.port or 1080,
        "version": "5"
    }

    if u.username:
        obj["username"] = unquote(u.username)

    if u.password:
        obj["password"] = unquote(u.password)

    print(json.dumps(obj, ensure_ascii=False, indent=2))

except Exception as e:
    print("ERROR:" + str(e))
    sys.exit(1)
PY
}

generate_config() {
    PROXY_JSON="$1"

    build_exclude_json

    cat > "$CONFIG" <<EOF
{
  "log": {
    "level": "warn"
  },

  "dns": {
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
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "route_exclude_address": [
        $EXCLUDE
      ]
    }
  ],

  "outbounds": [
    $PROXY_JSON,

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
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF
}

validate_config() {
    sing-box check -c "$CONFIG"
}

start_proxy() {
    systemctl daemon-reload >/dev/null 2>&1

    systemctl enable sing-box >/dev/null 2>&1

    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then
        return 0
    fi

    return 1
}

stop_proxy() {
    systemctl stop sing-box >/dev/null 2>&1

    if ip link show singtun0 >/dev/null 2>&1; then
        ip link delete singtun0 >/dev/null 2>&1
    fi
}

configure_proxy() {
    clear

    echo "======================================"
    echo "             配置出口代理"
    echo "======================================"
    echo ""
    echo "1. VLESS + WS + TLS"
    echo "2. VLESS + Reality"
    echo "3. SOCKS5"
    echo "0. 返回"
    echo ""

    read -r -p "请选择: " TYPE

    clear

    case "$TYPE" in

        1)
            echo "======================================"
            echo "       VLESS + WS + TLS"
            echo "======================================"
            echo ""
            echo "请粘贴完整 VLESS 链接："
            echo ""

            read -r NODE

            if [ -z "$NODE" ]; then
                echo ""
                echo "链接不能为空"
                read -r -p "按回车返回..."
                return
            fi

            PROXY_JSON=$(parse_vless "$NODE" ws 2>&1)

            if echo "$PROXY_JSON" | grep -q "^ERROR:"; then
                echo ""
                echo "解析失败："
                echo "$PROXY_JSON"
                read -r -p "按回车返回..."
                return
            fi
            ;;

        2)
            echo "======================================"
            echo "          VLESS + Reality"
            echo "======================================"
            echo ""
            echo "请粘贴完整 VLESS Reality 链接："
            echo ""

            read -r NODE

            if [ -z "$NODE" ]; then
                echo ""
                echo "链接不能为空"
                read -r -p "按回车返回..."
                return
            fi

            PROXY_JSON=$(parse_vless "$NODE" reality 2>&1)

            if echo "$PROXY_JSON" | grep -q "^ERROR:"; then
                echo ""
                echo "解析失败："
                echo "$PROXY_JSON"
                read -r -p "按回车返回..."
                return
            fi
            ;;

        3)
            echo "======================================"
            echo "               SOCKS5"
            echo "======================================"
            echo ""
            echo "支持："
            echo "socks5://user:password@server:port"
            echo ""
            echo "请粘贴 SOCKS5 链接："
            echo ""

            read -r NODE

            if [ -z "$NODE" ]; then
                echo ""
                echo "链接不能为空"
                read -r -p "按回车返回..."
                return
            fi

            PROXY_JSON=$(parse_socks "$NODE" 2>&1)

            if echo "$PROXY_JSON" | grep -q "^ERROR:"; then
                echo ""
                echo "解析失败："
                echo "$PROXY_JSON"
                read -r -p "按回车返回..."
                return
            fi
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

    clear

    echo "======================================"
    echo "           正在生成配置"
    echo "======================================"
    echo ""

    if [ -f "$CONFIG" ]; then
        cp -f "$CONFIG" "$BACKUP"
    fi

    generate_config "$PROXY_JSON"

    echo "正在检查 sing-box 配置..."
    echo ""

    if ! validate_config; then
        echo ""
        echo "配置检查失败"

        if [ -f "$BACKUP" ]; then
            cp -f "$BACKUP" "$CONFIG"
            echo ""
            echo "已恢复之前的配置"
        fi

        read -r -p "按回车返回..."
        return
    fi

    echo ""
    echo "配置检查通过"
    echo ""
    echo "正在启动全局代理..."

    if start_proxy; then

        clear

        echo "======================================"
        echo "           配置完成"
        echo "======================================"
        echo ""
        echo "全局代理：已开启"
        echo "TUN：singtun0"
        echo "配置文件：$CONFIG"

        if [ -n "$SSH_IP" ]; then
            echo ""
            echo "当前 SSH 客户端已加入直连排除"
        fi

        echo ""
        echo "当前出口由你刚才提供的节点负责"
        echo ""

    else

        echo ""
        echo "启动失败"
        echo ""
        echo "最近日志："
        echo ""

        journalctl -u sing-box -n 30 --no-pager 2>/dev/null

    fi

    echo ""
    read -r -p "按回车返回..."
}

disable_proxy() {
    clear

    echo "======================================"
    echo "           关闭全局代理"
    echo "======================================"
    echo ""

    stop_proxy

    echo "全局代理已关闭"
    echo ""
    echo "sing-box 服务已停止"
    echo ""

    read -r -p "按回车返回..."
}

show_status() {
    clear

    echo "======================================"
    echo "             当前状态"
    echo "======================================"
    echo ""

    if command -v sing-box >/dev/null 2>&1; then
        echo "sing-box：已安装"
        echo "版本："
        sing-box version | head -n 1
    else
        echo "sing-box：未安装"
    fi

    echo ""

    if systemctl is-active --quiet sing-box; then
        echo "代理状态：运行中"
    else
        echo "代理状态：未运行"
    fi

    echo ""

    if ip link show singtun0 >/dev/null 2>&1; then
        echo "TUN：singtun0"
        echo "TUN 状态：存在"
    else
        echo "TUN：不存在"
    fi

    echo ""

    if [ -f "$CONFIG" ]; then
        echo "配置文件：存在"
    else
        echo "配置文件：不存在"
    fi

    echo ""

    if systemctl is-active --quiet sing-box; then
        echo "最近日志："
        echo ""
        journalctl -u sing-box -n 15 --no-pager 2>/dev/null
    fi

    echo ""
    read -r -p "按回车返回..."
}

install_shortcuts() {
    cp -f "$0" "$INSTALL_PATH" 2>/dev/null || true
    chmod +x "$INSTALL_PATH" 2>/dev/null || true

    ln -sf "$INSTALL_PATH" "$OUT_PATH"
}

initial_install() {

    mkdir -p /etc/sing-box
    mkdir -p /etc/vps-out

    if ! command -v curl >/dev/null 2>&1 ||
       ! command -v python3 >/dev/null 2>&1; then

        install_basic || {
            echo ""
            echo "基础依赖安装失败"
            exit 1
        }
    fi

    if ! command -v sing-box >/dev/null 2>&1; then

        echo ""
        echo "未检测到 sing-box"
        echo "正在自动安装..."
        echo ""

        curl -fsSL https://sing-box.app/install.sh | sh

        if ! command -v sing-box >/dev/null 2>&1; then
            echo ""
            echo "sing-box 自动安装失败"
            exit 1
        fi

        systemctl daemon-reload >/dev/null 2>&1
    fi

    install_shortcuts
}

initial_install

while true
do
    clear

    echo "======================================"
    echo "          VPS 全局出口代理"
    echo "======================================"
    echo ""
    echo "1. 配置出口代理"
    echo "2. 关闭全局代理"
    echo "3. 查看当前状态"
    echo "4. 安装 / 更新 sing-box"
    echo "0. 退出"
    echo ""
    echo "快捷命令：out"
    echo ""

    read -r -p "请选择: " CHOICE

    clear

    case "$CHOICE" in

        1)
            configure_proxy
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

        0)
            clear
            exit 0
            ;;

        *)
            echo "无效选择"
            sleep 1
            ;;
    esac
done
