#!/bin/bash

# =========================================================
# VPS 全局代理管理脚本
# 支持：
# 1. VLESS + WS + TLS
# 2. SOCKS5
# 3. VLESS + Reality
# =========================================================

CONFIG="/etc/sing-box/config.json"
BACKUP="/etc/sing-box/config.json.bak"
BIN="/usr/local/bin/vps-out"
SHORTCUT="/usr/local/bin/out"

TUN_NAME="singtun0"

# ---------------------------------------------------------
# 基础函数
# ---------------------------------------------------------

pause() {
    echo
    read -r -p "按回车继续..." _
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "请使用 root 用户运行此脚本。"
        exit 1
    fi
}

clear_screen() {
    clear
}

# ---------------------------------------------------------
# 检测系统
# ---------------------------------------------------------

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        VERSION="$VERSION_ID"
    else
        OS="unknown"
    fi
}

# ---------------------------------------------------------
# 安装基础依赖
# ---------------------------------------------------------

install_dependencies() {

    detect_os

    echo "正在安装基础依赖..."

    case "$OS" in

        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive

            apt-get update -y

            apt-get install -y \
                curl \
                wget \
                jq \
                python3 \
                iproute2 \
                ca-certificates \
                unzip \
                tar
            ;;

        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y \
                    curl \
                    wget \
                    jq \
                    python3 \
                    iproute \
                    ca-certificates \
                    unzip \
                    tar
            else
                yum install -y \
                    curl \
                    wget \
                    jq \
                    python3 \
                    iproute \
                    ca-certificates \
                    unzip \
                    tar
            fi
            ;;

        alpine)
            apk update
            apk add \
                curl \
                wget \
                jq \
                python3 \
                iproute2 \
                ca-certificates \
                unzip \
                tar
            ;;

        *)
            echo "无法自动识别系统：$OS"
            echo "请手动安装：curl wget jq python3 iproute2"
            return 1
            ;;
    esac

    echo "基础依赖安装完成。"
}

# ---------------------------------------------------------
# 安装 / 更新 sing-box
# ---------------------------------------------------------

install_singbox() {

    clear_screen

    echo "========================================"
    echo "        安装 / 更新 sing-box"
    echo "========================================"
    echo

    install_dependencies || {
        echo
        echo "基础依赖安装失败。"
        pause
        return 1
    }

    echo
    echo "正在安装 / 更新最新版 sing-box..."
    echo

    if ! curl -fsSL https://sing-box.app/install.sh | sh; then
        echo
        echo "sing-box 安装失败。"
        pause
        return 1
    fi

    mkdir -p /etc/sing-box
    mkdir -p /etc/vps-out

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1
    fi

    if command -v sing-box >/dev/null 2>&1; then
        echo
        echo "sing-box 安装成功。"
        echo
        sing-box version
    else
        echo
        echo "没有找到 sing-box 命令。"
        pause
        return 1
    fi

    echo
    echo "安装完成。"
    pause
}

# ---------------------------------------------------------
# 检查 sing-box
# ---------------------------------------------------------

check_singbox() {

    if command -v sing-box >/dev/null 2>&1; then
        return 0
    fi

    echo "未检测到 sing-box。"
    echo "请先使用菜单中的「安装 / 更新 sing-box」。"
    pause
    return 1
}

# ---------------------------------------------------------
# 安装快捷命令
# ---------------------------------------------------------

install_shortcut() {

    mkdir -p /usr/local/bin

    if [ -f "$0" ] && [ "$0" != "/dev/stdin" ] && [ "$0" != "/dev/fd/63" ]; then

        cp "$0" "$BIN" 2>/dev/null

        if [ -f "$BIN" ]; then
            chmod +x "$BIN"
        fi

    fi

    if [ ! -x "$BIN" ]; then
        cat > "$BIN" <<'EOF'
#!/bin/bash
exec /usr/local/bin/vps-out
EOF
        chmod +x "$BIN"
    fi

    ln -sf "$BIN" "$SHORTCUT"
    chmod +x "$SHORTCUT"
}

# ---------------------------------------------------------
# Python URL 解析
# ---------------------------------------------------------

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

    if not u.hostname:
        raise Exception("缺少服务器地址")

    if not u.port:
        raise Exception("缺少服务器端口")

    uuid = unquote(u.username or "")

    if not uuid:
        raise Exception("缺少 UUID")

    q = parse_qs(u.query)

    def get(name, default=""):
        return unquote(q.get(name, [default])[0])

    security = get("security", "").lower()
    transport = get("type", "tcp").lower()

    server = u.hostname
    port = u.port

    obj = {
        "type": "vless",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "uuid": uuid
    }

    # -----------------------------------------------------
    # TLS
    # -----------------------------------------------------

    if security == "tls":

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

        alpn = get("alpn")

        if alpn:
            tls["alpn"] = [
                x.strip()
                for x in alpn.split(",")
                if x.strip()
            ]

        obj["tls"] = tls

    # -----------------------------------------------------
    # Reality
    # -----------------------------------------------------

    elif security == "reality":

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

        pbk = get("pbk")

        if not pbk:
            raise Exception("Reality 缺少 pbk 公钥")

        reality = {
            "enabled": True,
            "public_key": pbk
        }

        sid = get("sid")

        if sid:
            reality["short_id"] = sid

        tls["reality"] = reality

        obj["tls"] = tls

        flow = get("flow")

        if flow:
            obj["flow"] = flow

    # -----------------------------------------------------
    # WS
    # -----------------------------------------------------

    if transport == "ws":

        path = get("path", "/")

        transport_obj = {
            "type": "ws",
            "path": path
        }

        host = get("host")

        if host:
            transport_obj["headers"] = {
                "Host": host
            }

        obj["transport"] = transport_obj

    # -----------------------------------------------------
    # TCP
    # -----------------------------------------------------

    elif transport in ("tcp", "raw"):

        # TCP 不需要 transport 配置
        pass

    # -----------------------------------------------------
    # HTTP
    # -----------------------------------------------------

    elif transport == "http":

        obj["transport"] = {
            "type": "http"
        }

        host = get("host")

        if host:
            obj["transport"]["host"] = [
                host
            ]

        path = get("path")

        if path:
            obj["transport"]["path"] = path

    # -----------------------------------------------------
    # flow
    # -----------------------------------------------------

    flow = get("flow")

    if flow and "flow" not in obj:
        obj["flow"] = flow

    with open(output, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)

except Exception as e:
    print("ERROR:" + str(e))
    sys.exit(1)
PY

    if [ $? -ne 0 ]; then
        return 1
    fi

    return 0
}

# ---------------------------------------------------------
# 解析 SOCKS5
# ---------------------------------------------------------

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

    if u.scheme.lower() not in ("socks", "socks5"):
        raise Exception("不是 SOCKS 链接")

    if not u.hostname:
        raise Exception("缺少 SOCKS5 服务器地址")

    if not u.port:
        raise Exception("缺少 SOCKS5 端口")

    obj = {
        "type": "socks",
        "tag": "proxy",
        "server": u.hostname,
        "server_port": u.port,
        "version": "5"
    }

    if u.username:
        obj["username"] = unquote(u.username)

    if u.password:
        obj["password"] = unquote(u.password)

    with open(output, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)

except Exception as e:
    print("ERROR:" + str(e))
    sys.exit(1)
PY

    [ $? -eq 0 ]
}

# ---------------------------------------------------------
# 获取当前 SSH 客户端 IP
# ---------------------------------------------------------

get_ssh_client_ip() {

    SSH_IP=""

    if [ -n "${SSH_CLIENT:-}" ]; then
        SSH_IP="$(echo "$SSH_CLIENT" | awk '{print $1}')"
    fi
}

# ---------------------------------------------------------
# 生成完整 sing-box 配置
# ---------------------------------------------------------

build_config() {

    local OUTBOUND="$1"

    get_ssh_client_ip

    mkdir -p /etc/sing-box

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
      "interface_name": "$TUN_NAME",
      "address": [
        "172.19.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "stack": "system"
    }
  ],

  "outbounds": [
    $OUTBOUND,

    {
      "type": "direct",
      "tag": "direct"
    },

    {
      "type": "block",
      "tag": "block"
    },

    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],

  "route": {
    "auto_detect_interface": true,
    "final": "proxy",
    "rules": [
      {
        "protocol": "dns",
        "action": "hijack-dns"
      }
    ]
  }
}
EOF

    # -----------------------------------------------------
    # 当前 SSH 客户端加入 TUN 排除
    # 防止重新路由导致 SSH 断线
    # -----------------------------------------------------

    if [ -n "$SSH_IP" ]; then

        python3 - "$CONFIG" "$SSH_IP" <<'PY'
import sys
import json

config = sys.argv[1]
ip = sys.argv[2]

with open(config, "r", encoding="utf-8") as f:
    data = json.load(f)

tun = data["inbounds"][0]

if "route_exclude_address" not in tun:
    tun["route_exclude_address"] = []

if ip not in tun["route_exclude_address"]:
    tun["route_exclude_address"].append(ip)

with open(config, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

    fi
}

# ---------------------------------------------------------
# 写入代理 outbound
# ---------------------------------------------------------

make_vless_outbound() {

    local NODE="$1"
    local TEMP="/tmp/vps-out-vless.json"

    rm -f "$TEMP"

    if ! parse_vless "$NODE" "$TEMP"; then
        echo "VLESS 链接解析失败。"
        rm -f "$TEMP"
        return 1
    fi

    if ! jq empty "$TEMP" >/dev/null 2>&1; then
        echo "VLESS 配置生成失败。"
        rm -f "$TEMP"
        return 1
    fi

    build_config "$(jq -c '.' "$TEMP")"

    rm -f "$TEMP"

    return 0
}

make_socks_outbound() {

    local NODE="$1"
    local TEMP="/tmp/vps-out-socks.json"

    rm -f "$TEMP"

    if ! parse_socks "$NODE" "$TEMP"; then
        echo "SOCKS5 链接解析失败。"
        rm -f "$TEMP"
        return 1
    fi

    if ! jq empty "$TEMP" >/dev/null 2>&1; then
        echo "SOCKS5 配置生成失败。"
        rm -f "$TEMP"
        return 1
    fi

    build_config "$(jq -c '.' "$TEMP")"

    rm -f "$TEMP"

    return 0
}

# ---------------------------------------------------------
# 检查配置
# ---------------------------------------------------------

check_config() {

    if ! command -v sing-box >/dev/null 2>&1; then
        echo "未安装 sing-box。"
        return 1
    fi

    if [ ! -f "$CONFIG" ]; then
        echo "配置文件不存在。"
        return 1
    fi

    echo "正在检查 sing-box 配置..."
    echo

    sing-box check -c "$CONFIG"
}

# ---------------------------------------------------------
# 启动代理
# ---------------------------------------------------------

start_proxy() {

    if ! command -v systemctl >/dev/null 2>&1; then
        echo "当前系统没有 systemd。"
        return 1
    fi

    systemctl daemon-reload >/dev/null 2>&1

    systemctl enable sing-box >/dev/null 2>&1

    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then
        return 0
    fi

    return 1
}

# ---------------------------------------------------------
# 配置 VLESS
# ---------------------------------------------------------

config_vless() {

    clear_screen

    echo "========================================"
    echo "        VLESS 节点配置"
    echo "========================================"
    echo
    echo "支持："
    echo "VLESS + WS + TLS"
    echo "VLESS + Reality"
    echo
    echo "请粘贴完整 VLESS 链接："
    echo

    read -r NODE

    clear_screen

    if [ -z "$NODE" ]; then
        echo "没有输入节点。"
        pause
        return
    fi

    case "$NODE" in
        vless://*)
            ;;
        *)
            echo "错误：请输入 vless:// 开头的链接。"
            pause
            return
            ;;
    esac

    check_singbox || return

    mkdir -p /etc/sing-box

    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP"
    fi

    echo "正在解析 VLESS 节点..."
    echo

    if ! make_vless_outbound "$NODE"; then

        echo
        echo "配置生成失败。"

        if [ -f "$BACKUP" ]; then
            cp "$BACKUP" "$CONFIG"
        fi

        pause
        return
    fi

    echo "正在检查配置..."
    echo

    if ! check_config; then

        echo
        echo "配置检查失败。"

        if [ -f "$BACKUP" ]; then
            cp "$BACKUP" "$CONFIG"
            echo "已恢复之前的配置。"
        fi

        pause
        return
    fi

    echo
    echo "配置检查通过。"
    echo
    echo "正在启动全局代理..."

    if start_proxy; then

        echo
        echo "========================================"
        echo "全局代理已开启"
        echo "========================================"

    else

        echo
        echo "sing-box 启动失败。"
        echo
        echo "查看日志："
        echo "journalctl -u sing-box -n 50 --no-pager"
    fi

    pause
}

# ---------------------------------------------------------
# 配置 SOCKS5
# ---------------------------------------------------------

config_socks() {

    clear_screen

    echo "========================================"
    echo "          SOCKS5 节点配置"
    echo "========================================"
    echo
    echo "支持格式："
    echo
    echo "socks5://用户名:密码@服务器:端口"
    echo "socks5://服务器:端口"
    echo
    echo "请粘贴完整 SOCKS5 链接："
    echo

    read -r NODE

    clear_screen

    if [ -z "$NODE" ]; then
        echo "没有输入节点。"
        pause
        return
    fi

    case "$NODE" in
        socks5://*|socks://*)
            ;;
        *)
            echo "错误：请输入 socks5:// 或 socks:// 开头的链接。"
            pause
            return
            ;;
    esac

    check_singbox || return

    mkdir -p /etc/sing-box

    if [ -f "$CONFIG" ]; then
        cp "$CONFIG" "$BACKUP"
    fi

    echo "正在解析 SOCKS5 节点..."
    echo

    if ! make_socks_outbound "$NODE"; then

        echo
        echo "配置生成失败。"

        if [ -f "$BACKUP" ]; then
            cp "$BACKUP" "$CONFIG"
        fi

        pause
        return
    fi

    echo "正在检查配置..."
    echo

    if ! check_config; then

        echo
        echo "配置检查失败。"

        if [ -f "$BACKUP" ]; then
            cp "$BACKUP" "$CONFIG"
            echo "已恢复之前的配置。"
        fi

        pause
        return
    fi

    echo
    echo "配置检查通过。"
    echo
    echo "正在启动全局代理..."

    if start_proxy; then

        echo
        echo "========================================"
        echo "全局代理已开启"
        echo "========================================"

    else

        echo
        echo "sing-box 启动失败。"
        echo
        echo "查看日志："
        echo "journalctl -u sing-box -n 50 --no-pager"
    fi

    pause
}

# ---------------------------------------------------------
# 配置菜单
# ---------------------------------------------------------

config_menu() {

    while true; do

        clear_screen

        echo "========================================"
        echo "          全局代理配置"
        echo "========================================"
        echo
        echo "1. VLESS + WS + TLS"
        echo "2. SOCKS5"
        echo "3. VLESS + Reality"
        echo "0. 返回"
        echo

        read -r -p "请选择: " TYPE

        clear_screen

        case "$TYPE" in

            1)
                config_vless
                ;;

            2)
                config_socks
                ;;

            3)
                config_vless
                ;;

            0)
                return
                ;;

            *)
                echo "无效选项。"
                pause
                ;;
        esac

    done
}

# ---------------------------------------------------------
# 关闭全局代理
# ---------------------------------------------------------

disable_proxy() {

    clear_screen

    echo "========================================"
    echo "          关闭全局代理"
    echo "========================================"
    echo

    if command -v systemctl >/dev/null 2>&1; then

        systemctl stop sing-box >/dev/null 2>&1
        systemctl disable sing-box >/dev/null 2>&1

    fi

    if ip link show "$TUN_NAME" >/dev/null 2>&1; then
        ip link delete "$TUN_NAME" >/dev/null 2>&1
    fi

    echo "全局代理已关闭。"
    echo

    pause
}

# ---------------------------------------------------------
# 查看状态
# ---------------------------------------------------------

show_status() {

    clear_screen

    echo "========================================"
    echo "            当前状态"
    echo "========================================"
    echo

    if command -v sing-box >/dev/null 2>&1; then

        echo "sing-box：已安装"
        echo

        sing-box version

    else

        echo "sing-box：未安装"

    fi

    echo
    echo "----------------------------------------"
    echo

    if command -v systemctl >/dev/null 2>&1; then

        if systemctl is-active --quiet sing-box; then
            echo "全局代理：运行中"
        else
            echo "全局代理：未运行"
        fi

    else

        echo "系统：没有 systemd"

    fi

    echo
    echo "----------------------------------------"
    echo

    if [ -f "$CONFIG" ]; then
        echo "配置文件：存在"
    else
        echo "配置文件：不存在"
    fi

    echo

    if ip link show "$TUN_NAME" >/dev/null 2>&1; then
        echo "TUN：运行中"
    else
        echo "TUN：未运行"
    fi

    echo

    if [ -L "$SHORTCUT" ] || [ -x "$SHORTCUT" ]; then
        echo "快捷命令：out"
    else
        echo "快捷命令：未安装"
    fi

    echo
    echo "----------------------------------------"
    echo

    if command -v systemctl >/dev/null 2>&1; then
        echo "服务状态："
        systemctl --no-pager --full status sing-box 2>/dev/null | head -n 15
    fi

    echo

    pause
}

# ---------------------------------------------------------
# 查看日志
# ---------------------------------------------------------

show_logs() {

    clear_screen

    echo "========================================"
    echo "          sing-box 日志"
    echo "========================================"
    echo

    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u sing-box -n 50 --no-pager
    else
        echo "当前系统不支持 journalctl。"
    fi

    echo

    pause
}

# ---------------------------------------------------------
# 完整安装
# ---------------------------------------------------------

install_all() {

    clear_screen

    echo "========================================"
    echo "          安装 / 更新"
    echo "========================================"
    echo

    install_dependencies || {
        pause
        return
    }

    echo
    echo "正在安装 / 更新 sing-box..."
    echo

    if curl -fsSL https://sing-box.app/install.sh | sh; then

        mkdir -p /etc/sing-box
        mkdir -p /etc/vps-out

        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1
        fi

        echo
        echo "sing-box 安装完成。"
        echo

        sing-box version

        echo
        echo "正在安装快捷命令..."

        install_shortcut

        echo
        echo "安装完成。"
        echo
        echo "以后可以直接输入："
        echo
        echo "out"
        echo
        echo "打开管理菜单。"

    else

        echo
        echo "sing-box 安装失败。"

    fi

    echo

    pause
}

# ---------------------------------------------------------
# 主菜单
# ---------------------------------------------------------

main_menu() {

    while true; do

        clear_screen

        echo "========================================"
        echo "          VPS 全局代理管理"
        echo "========================================"
        echo
        echo "1. 安装 / 更新 sing-box"
        echo "2. 配置全局代理"
        echo "3. 关闭全局代理"
        echo "4. 查看状态"
        echo "5. 查看日志"
        echo "0. 退出"
        echo
        echo "----------------------------------------"
        echo

        read -r -p "请选择: " CHOICE

        clear_screen

        case "$CHOICE" in

            1)
                install_all
                ;;

            2)
                config_menu
                ;;

            3)
                disable_proxy
                ;;

            4)
                show_status
                ;;

            5)
                show_logs
                ;;

            0)
                clear_screen
                exit 0
                ;;

            *)
                echo "无效选项。"
                pause
                ;;

        esac

    done
}

# ---------------------------------------------------------
# 启动
# ---------------------------------------------------------

check_root

mkdir -p /etc/sing-box
mkdir -p /etc/vps-out

install_shortcut

main_menu
