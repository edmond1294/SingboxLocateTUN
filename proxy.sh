#!/bin/bash

# =========================================================
# VPS 全局代理脚本
# 支持：
# 1. VLESS + WS + TLS
# 2. VLESS + Reality
# 3. SOCKS5
#
# sing-box + TUN
# VPS 自身出口 + 普通程序出口全部经过代理
# =========================================================

set -u

CONFIG="/etc/sing-box/config.json"
BACKUP="/etc/sing-box/config.json.bak"
WORKDIR="/etc/vps-out"
SCRIPT="/usr/local/bin/vps-out"
SHORTCUT="/usr/local/bin/out"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

mkdir -p /etc/sing-box
mkdir -p "$WORKDIR"

# =========================================================
# 基础依赖
# =========================================================

install_basic() {

    export DEBIAN_FRONTEND=noninteractive

    if command -v apt-get >/dev/null 2>&1; then

        apt-get update -y >/dev/null 2>&1

        apt-get install -y \
            curl \
            wget \
            ca-certificates \
            unzip \
            tar \
            gzip \
            iproute2 \
            iptables \
            iptables-persistent \
            python3 \
            jq \
            >/dev/null 2>&1

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y \
            curl \
            wget \
            ca-certificates \
            unzip \
            tar \
            gzip \
            iproute \
            iptables \
            python3 \
            jq \
            >/dev/null 2>&1

    elif command -v yum >/dev/null 2>&1; then

        yum install -y \
            curl \
            wget \
            ca-certificates \
            unzip \
            tar \
            gzip \
            iproute \
            iptables \
            python3 \
            jq \
            >/dev/null 2>&1

    elif command -v apk >/dev/null 2>&1; then

        apk add --no-cache \
            curl \
            wget \
            ca-certificates \
            unzip \
            tar \
            gzip \
            iproute2 \
            iptables \
            python3 \
            jq \
            >/dev/null 2>&1
    fi
}

# =========================================================
# 安装 sing-box
# =========================================================

install_singbox() {

    if command -v sing-box >/dev/null 2>&1; then
        return 0
    fi

    echo "正在安装 sing-box..."

    curl -fsSL https://sing-box.app/install.sh | sh

    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${RED}sing-box 安装失败${RESET}"
        exit 1
    fi
}

# =========================================================
# 判断是否 root
# =========================================================

check_root() {

    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请使用 root 用户运行${RESET}"
        exit 1
    fi
}

# =========================================================
# 安装快捷命令
# =========================================================

install_shortcut() {

    if [ -f "$0" ] && [ "$0" != "/dev/fd/63" ]; then

        cp "$0" "$SCRIPT" >/dev/null 2>&1
        chmod +x "$SCRIPT" >/dev/null 2>&1

    fi

    if [ ! -f "$SCRIPT" ]; then
        return 0
    fi

    ln -sf "$SCRIPT" "$SHORTCUT"
    chmod +x "$SCRIPT"
}

# =========================================================
# 获取 SSH 客户端 IP
# =========================================================

get_ssh_client_ip() {

    SSH_CLIENT_IP=""

    if [ -n "${SSH_CLIENT:-}" ]; then
        SSH_CLIENT_IP="$(echo "$SSH_CLIENT" | awk '{print $1}')"
    fi
}

# =========================================================
# 生成 TUN 配置
# =========================================================

generate_config() {

    local OUTBOUND_JSON="$1"

    get_ssh_client_ip

    local EXCLUDE='
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "::1/128",
        "fc00::/7",
        "fe80::/10"
    '

    if [ -n "$SSH_CLIENT_IP" ]; then

        if echo "$SSH_CLIENT_IP" | grep -q ':'; then
            EXCLUDE="$EXCLUDE,
        \"$SSH_CLIENT_IP/128\""
        else
            EXCLUDE="$EXCLUDE,
        \"$SSH_CLIENT_IP/32\""
        fi

    fi

    cat > "$CONFIG" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
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
      "mtu": 1500,
      "auto_route": true,
      "strict_route": true,
      "stack": "system"
    }
  ],

  "outbounds": [
    $OUTBOUND_JSON,

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

    "rules": [
      {
        "protocol": "dns",
        "action": "hijack-dns"
      }
    ],

    "final": "proxy"
  }
}
EOF
}

# =========================================================
# VLESS WS TLS 解析
# =========================================================

parse_vless_ws() {

    local URL="$1"

    python3 - "$URL" <<'PY' > "$WORKDIR/outbound.json"
import sys
from urllib.parse import urlsplit, parse_qs, unquote
import json

url = sys.argv[1]

u = urlsplit(url)

if u.scheme.lower() != "vless":
    raise SystemExit("不是 VLESS 链接")

q = parse_qs(u.query)

uuid = unquote(u.username or "")
server = u.hostname
port = u.port or 443

security = q.get("security", [""])[0].lower()
transport = q.get("type", [""])[0].lower()

if not uuid:
    raise SystemExit("缺少 UUID")

if not server:
    raise SystemExit("缺少服务器地址")

if security != "tls":
    raise SystemExit("该链接不是 TLS")

if transport != "ws":
    raise SystemExit("该链接不是 WS")

sni = q.get("sni", [server])[0]
fp = q.get("fp", ["chrome"])[0]
host = q.get("host", [sni])[0]
path = unquote(q.get("path", ["/"])[0])

obj = {
    "type": "vless",
    "tag": "proxy",
    "server": server,
    "server_port": port,
    "uuid": uuid,
    "tls": {
        "enabled": True,
        "server_name": sni,
        "utls": {
            "enabled": True,
            "fingerprint": fp
        }
    },
    "transport": {
        "type": "ws",
        "path": path,
        "headers": {
            "Host": host
        }
    }
}

flow = q.get("flow", [""])[0]

if flow:
    obj["flow"] = flow

print(json.dumps(obj, ensure_ascii=False, indent=2))
PY

    if [ $? -ne 0 ]; then
        return 1
    fi

    return 0
}

# =========================================================
# VLESS Reality 解析
# =========================================================

parse_vless_reality() {

    local URL="$1"

    python3 - "$URL" <<'PY' > "$WORKDIR/outbound.json"
import sys
from urllib.parse import urlsplit, parse_qs, unquote
import json

url = sys.argv[1]

u = urlsplit(url)

if u.scheme.lower() != "vless":
    raise SystemExit("不是 VLESS 链接")

q = parse_qs(u.query)

uuid = unquote(u.username or "")
server = u.hostname
port = u.port or 443

security = q.get("security", [""])[0].lower()

if security != "reality":
    raise SystemExit("该链接不是 Reality")

if not uuid:
    raise SystemExit("缺少 UUID")

if not server:
    raise SystemExit("缺少服务器地址")

sni = q.get("sni", [""])[0]
fp = q.get("fp", ["chrome"])[0]
pbk = q.get("pbk", [""])[0]
sid = q.get("sid", [""])[0]
flow = q.get("flow", [""])[0]

if not sni:
    raise SystemExit("Reality 缺少 SNI")

if not pbk:
    raise SystemExit("Reality 缺少公钥 pbk")

obj = {
    "type": "vless",
    "tag": "proxy",
    "server": server,
    "server_port": port,
    "uuid": uuid,
    "tls": {
        "enabled": True,
        "server_name": sni,
        "utls": {
            "enabled": True,
            "fingerprint": fp
        },
        "reality": {
            "enabled": True,
            "public_key": pbk
        }
    }
}

if sid:
    obj["tls"]["reality"]["short_id"] = sid

if flow:
    obj["flow"] = flow

print(json.dumps(obj, ensure_ascii=False, indent=2))
PY

    if [ $? -ne 0 ]; then
        return 1
    fi

    return 0
}

# =========================================================
# SOCKS5 解析
# =========================================================

parse_socks() {

    local URL="$1"

    python3 - "$URL" <<'PY' > "$WORKDIR/outbound.json"
import sys
from urllib.parse import urlsplit, unquote
import json

url = sys.argv[1]

u = urlsplit(url)

if u.scheme.lower() not in ["socks", "socks5"]:
    raise SystemExit("不是 SOCKS5 链接")

server = u.hostname
port = u.port or 1080

if not server:
    raise SystemExit("缺少 SOCKS5 地址")

obj = {
    "type": "socks",
    "tag": "proxy",
    "server": server,
    "server_port": port,
    "version": "5"
}

if u.username:
    obj["username"] = unquote(u.username)

if u.password:
    obj["password"] = unquote(u.password)

print(json.dumps(obj, ensure_ascii=False, indent=2))
PY

    if [ $? -ne 0 ]; then
        return 1
    fi

    return 0
}

# =========================================================
# 安装/启动 sing-box 服务
# =========================================================

restart_service() {

    systemctl daemon-reload >/dev/null 2>&1

    systemctl enable sing-box >/dev/null 2>&1

    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then
        return 0
    fi

    return 1
}

# =========================================================
# 配置代理
# =========================================================

configure_proxy() {

    clear

    echo "========================================"
    echo "           选择代理类型"
    echo "========================================"
    echo
    echo "1. VLESS + WS + TLS"
    echo "2. SOCKS5"
    echo "3. VLESS + Reality"
    echo "0. 返回"
    echo
    read -r -p "请选择: " TYPE

    clear

    case "$TYPE" in

        1)

            echo "========================================"
            echo "       VLESS + WS + TLS"
            echo "========================================"
            echo
            read -r -p "请粘贴 VLESS 链接: " URL

            if ! parse_vless_ws "$URL"; then
                echo
                echo -e "${RED}VLESS WS TLS 链接解析失败${RESET}"
                read -r -p "按回车返回..."
                return
            fi

            ;;

        2)

            echo "========================================"
            echo "              SOCKS5"
            echo "========================================"
            echo
            read -r -p "请粘贴 SOCKS5 链接: " URL

            if ! parse_socks "$URL"; then
                echo
                echo -e "${RED}SOCKS5 链接解析失败${RESET}"
                read -r -p "按回车返回..."
                return
            fi

            ;;

        3)

            echo "========================================"
            echo "          VLESS + Reality"
            echo "========================================"
            echo
            read -r -p "请粘贴 VLESS Reality 链接: " URL

            if ! parse_vless_reality "$URL"; then
                echo
                echo -e "${RED}VLESS Reality 链接解析失败${RESET}"
                read -r -p "按回车返回..."
                return
            fi

            ;;

        0)
            return
            ;;

        *)
            echo "无效选择"
            sleep 1
            return
            ;;

    esac

    if [ ! -f "$WORKDIR/outbound.json" ]; then
        echo
        echo -e "${RED}代理配置生成失败${RESET}"
        read -r -p "按回车返回..."
        return
    fi

    clear

    echo "正在生成 sing-box 配置..."

    if [ -f "$CONFIG" ]; then
        cp -f "$CONFIG" "$BACKUP"
    fi

    OUTBOUND_JSON="$(cat "$WORKDIR/outbound.json")"

    generate_config "$OUTBOUND_JSON"

    chmod 600 "$CONFIG"

    echo "正在检查配置..."

    if ! sing-box check -c "$CONFIG"; then

        echo
        echo -e "${RED}配置检查失败${RESET}"

        if [ -f "$BACKUP" ]; then
            cp -f "$BACKUP" "$CONFIG"
        fi

        rm -f "$WORKDIR/outbound.json"

        read -r -p "按回车返回..."
        return
    fi

    echo
    echo "配置检查通过"
    echo "正在启动 sing-box..."

    if restart_service; then

        echo
        echo -e "${GREEN}代理配置成功${RESET}"
        echo
        echo "当前 VPS 出口已通过 TUN 接管"
        echo "sing-box 已设置为开机启动"

    else

        echo
        echo -e "${RED}sing-box 启动失败${RESET}"
        echo
        echo "查看日志："
        echo "journalctl -u sing-box -n 50 --no-pager"

    fi

    rm -f "$WORKDIR/outbound.json"

    echo
    read -r -p "按回车返回主菜单..."
}

# =========================================================
# 关闭全局代理
# =========================================================

disable_proxy() {

    clear

    echo "正在关闭全局代理..."

    systemctl stop sing-box >/dev/null 2>&1

    systemctl disable sing-box >/dev/null 2>&1

    ip link delete singtun0 >/dev/null 2>&1 || true

    echo
    echo -e "${GREEN}全局代理已关闭${RESET}"
    echo

    read -r -p "按回车返回主菜单..."
}

# =========================================================
# 查看状态
# =========================================================

show_status() {

    clear

    echo "========================================"
    echo "              当前状态"
    echo "========================================"
    echo

    if systemctl is-active --quiet sing-box; then
        echo -e "sing-box：${GREEN}运行中${RESET}"
    else
        echo -e "sing-box：${RED}未运行${RESET}"
    fi

    echo

    if ip link show singtun0 >/dev/null 2>&1; then
        echo -e "TUN：${GREEN}已创建${RESET}"
    else
        echo -e "TUN：${RED}不存在${RESET}"
    fi

    echo

    if [ -f "$CONFIG" ]; then
        echo "配置文件：$CONFIG"
    else
        echo "配置文件：不存在"
    fi

    echo

    if [ -f "$CONFIG" ]; then

        echo "当前代理："

        python3 - "$CONFIG" <<'PY'
import json

try:
    with open("/etc/sing-box/config.json", "r") as f:
        c = json.load(f)

    for o in c.get("outbounds", []):
        if o.get("tag") == "proxy":
            print("类型：", o.get("type", "未知"))
            print("服务器：", o.get("server", "未知"))
            print("端口：", o.get("server_port", "未知"))

            if o.get("transport"):
                print("传输：", o["transport"].get("type", "未知"))

            tls = o.get("tls", {})

            if tls.get("enabled"):
                print("TLS：已启用")

            if tls.get("reality", {}).get("enabled"):
                print("Reality：已启用")

except Exception:
    print("配置读取失败")
PY

    fi

    echo
    echo "最近日志："
    echo "----------------------------------------"

    journalctl -u sing-box -n 15 --no-pager 2>/dev/null

    echo "----------------------------------------"
    echo

    read -r -p "按回车返回主菜单..."
}

# =========================================================
# 卸载
# =========================================================

uninstall_proxy() {

    clear

    echo "正在停止 sing-box..."

    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true

    ip link delete singtun0 >/dev/null 2>&1 || true

    rm -f "$CONFIG"
    rm -f "$SHORTCUT"
    rm -f "$SCRIPT"

    echo
    echo "全局代理配置已删除"
    echo
    read -r -p "按回车退出..."
    exit 0
}

# =========================================================
# 主菜单
# =========================================================

while true
do

    clear

    echo "========================================"
    echo "             VPS 全局代理"
    echo "========================================"
    echo
    echo "1. 配置代理"
    echo "2. 关闭全局代理"
    echo "3. 查看状态"
    echo "4. 卸载脚本"
    echo "0. 退出"
    echo
    echo "快捷命令：out"
    echo

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
            uninstall_proxy
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
