#!/bin/bash

# ============================================================
# sing-box 全局出口管理脚本
# 支持：
# 1. VLESS + WS + TLS
# 2. VLESS + Reality
# 3. SOCKS5
#
# 使用方式：
# bash proxy.sh
# 或：
# sbout
# ============================================================

set +e

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
NODE_FILE="$CONFIG_DIR/node.txt"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
BIN="/usr/local/bin/sing-box"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

pause() {
    echo
    read -r -p "按回车返回菜单..." _
}

need_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请使用 root 运行此脚本${RESET}"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        VERSION_ID="$VERSION_ID"
    else
        OS="unknown"
    fi

    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64|amd64)
            SB_ARCH="amd64"
            ;;
        aarch64|arm64)
            SB_ARCH="arm64"
            ;;
        armv7l|armv7)
            SB_ARCH="armv7"
            ;;
        i386|i686)
            SB_ARCH="386"
            ;;
        *)
            SB_ARCH=""
            ;;
    esac
}

install_dependencies() {

    echo
    echo "正在检查系统依赖..."

    case "$OS" in
        debian|ubuntu)
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl wget unzip tar ca-certificates >/dev/null 2>&1
            ;;

        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y curl wget unzip tar ca-certificates >/dev/null 2>&1
            else
                yum install -y curl wget unzip tar ca-certificates >/dev/null 2>&1
            fi
            ;;

        arch|manjaro)
            pacman -Sy --noconfirm curl wget unzip tar ca-certificates >/dev/null 2>&1
            ;;

        alpine)
            apk add --no-cache curl wget unzip tar ca-certificates >/dev/null 2>&1
            ;;

        amazon)
            yum install -y curl wget unzip tar ca-certificates >/dev/null 2>&1
            ;;
    esac
}

install_singbox() {

    echo
    echo "======================================"
    echo "        安装 sing-box"
    echo "======================================"
    echo

    if command -v sing-box >/dev/null 2>&1; then
        BIN="$(command -v sing-box)"
        echo "检测到 sing-box：$BIN"
        "$BIN" version
        return 0
    fi

    if [ -x "/usr/local/bin/sing-box" ]; then
        BIN="/usr/local/bin/sing-box"
        echo "检测到 sing-box：$BIN"
        "$BIN" version
        return 0
    fi

    install_dependencies

    echo
    echo "正在安装 sing-box..."
    echo

    # 官方安装方式
    if curl -fsSL https://sing-box.app/install.sh -o /tmp/sing-box-install.sh; then

        chmod +x /tmp/sing-box-install.sh

        bash /tmp/sing-box-install.sh

        rm -f /tmp/sing-box-install.sh

    fi

    if [ -x "/usr/local/bin/sing-box" ]; then
        BIN="/usr/local/bin/sing-box"
    elif command -v sing-box >/dev/null 2>&1; then
        BIN="$(command -v sing-box)"
    fi

    if [ ! -x "$BIN" ]; then

        echo
        echo "官方安装程序未成功安装，尝试 GitHub..."

        TMP="/tmp/singbox"

        rm -rf "$TMP"
        mkdir -p "$TMP"

        API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

        curl -fsSL "$API" -o "$TMP/release.json"

        if [ ! -s "$TMP/release.json" ]; then
            echo -e "${RED}无法获取 sing-box 最新版本${RESET}"
            return 1
        fi

        DOWNLOAD_URL="$(python3 - "$SB_ARCH" "$TMP/release.json" <<'PY'
import json
import sys

arch = sys.argv[1]
file = sys.argv[2]

with open(file, "r", encoding="utf-8") as f:
    data = json.load(f)

for asset in data.get("assets", []):
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")

    if (
        name.endswith(".tar.gz")
        and "linux" in name
        and arch in name
        and "legacy" not in name
    ):
        print(url)
        break
PY
)"

        if [ -z "$DOWNLOAD_URL" ]; then
            echo -e "${RED}没有找到适合当前系统架构的 sing-box${RESET}"
            return 1
        fi

        echo "正在下载..."
        curl -fL "$DOWNLOAD_URL" -o "$TMP/sing-box.tar.gz"

        if [ ! -s "$TMP/sing-box.tar.gz" ]; then
            echo -e "${RED}下载失败${RESET}"
            return 1
        fi

        tar -xzf "$TMP/sing-box.tar.gz" -C "$TMP"

        FOUND="$(find "$TMP" -type f -name sing-box | head -n 1)"

        if [ -z "$FOUND" ]; then
            echo -e "${RED}解压后没有找到 sing-box${RESET}"
            return 1
        fi

        install -m 755 "$FOUND" /usr/local/bin/sing-box

        BIN="/usr/local/bin/sing-box"

        rm -rf "$TMP"
    fi

    if [ ! -x "$BIN" ]; then
        echo -e "${RED}sing-box 安装失败${RESET}"
        return 1
    fi

    echo
    echo -e "${GREEN}sing-box 安装成功${RESET}"
    "$BIN" version

    return 0
}

make_dirs() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
}

install_service() {

    if command -v systemctl >/dev/null 2>&1; then

        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box Global Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -c $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1

        SERVICE_MODE="systemd"

    elif command -v rc-service >/dev/null 2>&1; then

        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box Global Proxy"

command="$BIN"
command_args="run -c $CONFIG_FILE"

command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF

        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1

        SERVICE_MODE="openrc"

    else

        SERVICE_MODE="none"
    fi
}

service_start() {

    case "$SERVICE_MODE" in

        systemd)
            systemctl restart sing-box
            ;;

        openrc)
            rc-service sing-box restart
            ;;

        *)
            echo "当前系统没有 systemd/openrc"
            return 1
            ;;
    esac
}

service_stop() {

    case "$SERVICE_MODE" in

        systemd)
            systemctl stop sing-box
            ;;

        openrc)
            rc-service sing-box stop
            ;;

        *)
            ;;
    esac
}

service_status() {

    case "$SERVICE_MODE" in

        systemd)
            systemctl status sing-box --no-pager
            ;;

        openrc)
            rc-service sing-box status
            ;;

        *)
            echo "没有可用的服务管理器"
            ;;
    esac
}

# ============================================================
# 解析 VLESS WS TLS
# ============================================================

parse_vless_ws() {

    URI="$1"

    case "$URI" in
        vless://*)
            ;;
        *)
            echo -e "${RED}这不是 VLESS 链接${RESET}"
            return 1
            ;;
    esac

    BODY="${URI#vless://}"

    BODY="${BODY%%#*}"

    USER_PART="${BODY%@*}"
    SERVER_PART="${BODY#*@}"

    UUID="$USER_PART"

    HOSTPORT="${SERVER_PART%%\?*}"

    PARAMS=""

    if [[ "$SERVER_PART" == *"?"* ]]; then
        PARAMS="${SERVER_PART#*\?}"
    fi

    SERVER="${HOSTPORT%:*}"
    PORT="${HOSTPORT##*:}"

    get_param() {
        local key="$1"

        echo "$PARAMS" | tr '&' '\n' | awk -F= -v k="$key" '$1==k {print substr($0,index($0,"=")+1)}' | head -n1
    }

    SECURITY="$(get_param security)"
    TYPE="$(get_param type)"
    SNI="$(get_param sni)"
    FP="$(get_param fp)"
    WS_HOST="$(get_param host)"
    WS_PATH="$(get_param path)"

    if [ -z "$UUID" ] || [ -z "$SERVER" ] || [ -z "$PORT" ]; then
        echo -e "${RED}VLESS 链接解析失败${RESET}"
        return 1
    fi

    if [ "$TYPE" != "ws" ]; then
        echo -e "${YELLOW}注意：你选择的是 VLESS + WS + TLS，但链接 type 不是 ws${RESET}"
    fi

    if [ "$SECURITY" != "tls" ]; then
        echo -e "${YELLOW}注意：你选择的是 VLESS + WS + TLS，但链接 security 不是 tls${RESET}"
    fi

    WS_PATH="$(python3 - "$WS_PATH" <<'PY'
import sys
from urllib.parse import unquote
print(unquote(sys.argv[1]))
PY
)"

    cat > "$NODE_FILE" <<EOF
protocol=vless_ws
server=$SERVER
port=$PORT
uuid=$UUID
sni=$SNI
host=$WS_HOST
path=$WS_PATH
fp=$FP
EOF

    echo
    echo "协议：VLESS + WS + TLS"
    echo "服务器：$SERVER"
    echo "端口：$PORT"
    echo "SNI：$SNI"
    echo "WS Host：$WS_HOST"
    echo "WS Path：$WS_PATH"
    echo "指纹：$FP"
    echo

    return 0
}

# ============================================================
# 解析 VLESS Reality
# ============================================================

parse_vless_reality() {

    URI="$1"

    case "$URI" in
        vless://*)
            ;;
        *)
            echo -e "${RED}这不是 VLESS 链接${RESET}"
            return 1
            ;;
    esac

    BODY="${URI#vless://}"
    BODY="${BODY%%#*}"

    USER_PART="${BODY%@*}"
    SERVER_PART="${BODY#*@}"

    UUID="$USER_PART"

    HOSTPORT="${SERVER_PART%%\?*}"

    PARAMS=""

    if [[ "$SERVER_PART" == *"?"* ]]; then
        PARAMS="${SERVER_PART#*\?}"
    fi

    SERVER="${HOSTPORT%:*}"
    PORT="${HOSTPORT##*:}"

    get_param() {
        local key="$1"

        echo "$PARAMS" | tr '&' '\n' | awk -F= -v k="$key" '$1==k {print substr($0,index($0,"=")+1)}' | head -n1
    }

    SECURITY="$(get_param security)"
    SNI="$(get_param sni)"
    FP="$(get_param fp)"
    PBK="$(get_param pbk)"
    SID="$(get_param sid)"
    FLOW="$(get_param flow)"

    if [ -z "$UUID" ] || [ -z "$SERVER" ] || [ -z "$PORT" ]; then
        echo -e "${RED}VLESS Reality 链接解析失败${RESET}"
        return 1
    fi

    if [ "$SECURITY" != "reality" ]; then
        echo -e "${YELLOW}注意：该链接 security 不是 reality${RESET}"
    fi

    cat > "$NODE_FILE" <<EOF
protocol=vless_reality
server=$SERVER
port=$PORT
uuid=$UUID
sni=$SNI
fp=$FP
pbk=$PBK
sid=$SID
flow=$FLOW
EOF

    echo
    echo "协议：VLESS + Reality"
    echo "服务器：$SERVER"
    echo "端口：$PORT"
    echo "SNI：$SNI"
    echo "指纹：$FP"
    echo "Short ID：$SID"
    echo

    return 0
}

# ============================================================
# 解析 SOCKS5
# ============================================================

parse_socks5() {

    URI="$1"

    case "$URI" in
        socks://*)
            ;;
        socks5://*)
            ;;
        *)
            echo -e "${RED}这不是 SOCKS5 链接${RESET}"
            return 1
            ;;
    esac

    BODY="${URI#*://}"
    BODY="${BODY%%#*}"

    USERINFO=""
    HOSTPART="$BODY"

    if [[ "$BODY" == *@* ]]; then
        USERINFO="${BODY%@*}"
        HOSTPART="${BODY#*@}"
    fi

    SERVER="${HOSTPART%:*}"
    PORT="${HOSTPART##*:}"

    USER=""
    PASS=""

    if [ -n "$USERINFO" ]; then
        USER="${USERINFO%%:*}"
        PASS="${USERINFO#*:}"
    fi

    if [ -z "$SERVER" ] || [ -z "$PORT" ]; then
        echo -e "${RED}SOCKS5 链接解析失败${RESET}"
        return 1
    fi

    cat > "$NODE_FILE" <<EOF
protocol=socks5
server=$SERVER
port=$PORT
user=$USER
pass=$PASS
EOF

    echo
    echo "协议：SOCKS5"
    echo "服务器：$SERVER"
    echo "端口：$PORT"
    echo "用户名：${USER:+已设置}"
    echo "密码：${PASS:+已设置}"
    echo

    return 0
}

# ============================================================
# 读取节点
# ============================================================

load_node() {

    if [ ! -f "$NODE_FILE" ]; then
        return 1
    fi

    unset protocol server port uuid sni host path fp pbk sid flow user pass

    while IFS='=' read -r key value; do
        case "$key" in
            protocol) protocol="$value" ;;
            server) server="$value" ;;
            port) port="$value" ;;
            uuid) uuid="$value" ;;
            sni) sni="$value" ;;
            host) host="$value" ;;
            path) path="$value" ;;
            fp) fp="$value" ;;
            pbk) pbk="$value" ;;
            sid) sid="$value" ;;
            flow) flow="$value" ;;
            user) user="$value" ;;
            pass) pass="$value" ;;
        esac
    done < "$NODE_FILE"

    return 0
}

# ============================================================
# 生成 sing-box 配置
# ============================================================

generate_config() {

    load_node

    if [ -z "$protocol" ]; then
        echo "没有配置节点"
        return 1
    fi

    make_dirs

    case "$protocol" in

        vless_ws)

            cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn"
  },

  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "1.1.1.1",
        "detour": "proxy-out"
      }
    ],
    "final": "dns-remote"
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
    {
      "type": "vless",
      "tag": "proxy-out",
      "server": "$server",
      "server_port": $port,
      "uuid": "$uuid",
      "network": "ws",

      "tls": {
        "enabled": true,
        "server_name": "$sni",

        "utls": {
          "enabled": true,
          "fingerprint": "${fp:-chrome}"
        }
      },

      "transport": {
        "type": "ws",
        "path": "$path",
        "headers": {
          "Host": "$host"
        }
      }
    },

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

    "final": "proxy-out"
  }
}
EOF
            ;;

        vless_reality)

            FLOW_JSON=""

            if [ -n "$flow" ]; then
                FLOW_JSON=",\n      \"flow\": \"$flow\""
            fi

            cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn"
  },

  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "1.1.1.1",
        "detour": "proxy-out"
      }
    ],
    "final": "dns-remote"
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
    {
      "type": "vless",
      "tag": "proxy-out",
      "server": "$server",
      "server_port": $port,
      "uuid": "$uuid"$FLOW_JSON,
      "network": "tcp",

      "tls": {
        "enabled": true,
        "server_name": "$sni",

        "utls": {
          "enabled": true,
          "fingerprint": "${fp:-chrome}"
        },

        "reality": {
          "enabled": true,
          "public_key": "$pbk",
          "short_id": "$sid"
        }
      }
    },

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

    "final": "proxy-out"
  }
}
EOF
            ;;

        socks5)

            AUTH=""

            if [ -n "$user" ]; then
                AUTH=$(cat <<EOF
,
      "username": "$user",
      "password": "$pass"
EOF
)
            fi

            cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "warn"
  },

  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "1.1.1.1",
        "detour": "proxy-out"
      }
    ],
    "final": "dns-remote"
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
    {
      "type": "socks",
      "tag": "proxy-out",
      "server": "$server",
      "server_port": $port$AUTH
    },

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

    "final": "proxy-out"
  }
}
EOF
            ;;

        *)
            echo "未知协议"
            return 1
            ;;
    esac

    chmod 600 "$CONFIG_FILE"

    echo
    echo "正在检查配置..."

    "$BIN" check -c "$CONFIG_FILE"

    if [ $? -ne 0 ]; then
        echo
        echo -e "${RED}sing-box 配置检查失败${RESET}"
        return 1
    fi

    echo
    echo -e "${GREEN}配置检查通过${RESET}"

    return 0
}

# ============================================================
# 选择协议并粘贴链接
# ============================================================

configure_node() {

    clear

    echo "======================================"
    echo "        配置 sing-box 出口"
    echo "======================================"
    echo
    echo "请选择协议："
    echo
    echo "1. VLESS + WS + TLS"
    echo "2. VLESS + Reality"
    echo "3. SOCKS5"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-3]: " CHOICE

    case "$CHOICE" in

        1)

            echo
            echo "请粘贴 VLESS + WS + TLS 链接"
            echo

            read -r -p "> " URI

            if [ -z "$URI" ]; then
                echo "链接不能为空"
                pause
                return
            fi

            parse_vless_ws "$URI"

            if [ $? -eq 0 ]; then
                generate_config
                install_service
            fi

            pause
            ;;

        2)

            echo
            echo "请粘贴 VLESS + Reality 链接"
            echo

            read -r -p "> " URI

            if [ -z "$URI" ]; then
                echo "链接不能为空"
                pause
                return
            fi

            parse_vless_reality "$URI"

            if [ $? -eq 0 ]; then
                generate_config
                install_service
            fi

            pause
            ;;

        3)

            echo
            echo "请粘贴 SOCKS5 链接"
            echo

            read -r -p "> " URI

            if [ -z "$URI" ]; then
                echo "链接不能为空"
                pause
                return
            fi

            parse_socks5 "$URI"

            if [ $? -eq 0 ]; then
                generate_config
                install_service
            fi

            pause
            ;;

        0)
            return
            ;;

        *)
            echo "无效选择"
            pause
            ;;
    esac
}

# ============================================================
# 启用
# ============================================================

enable_proxy() {

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "请先配置节点"
        pause
        return
    fi

    install_service

    echo
    echo "正在启动 sing-box..."

    service_start

    sleep 2

    if service_running; then
        echo
        echo -e "${GREEN}全局代理已开启${RESET}"
    else
        echo
        echo -e "${RED}启动失败${RESET}"
    fi

    pause
}

# ============================================================
# 停止
# ============================================================

disable_proxy() {

    service_stop

    echo
    echo -e "${GREEN}全局代理已关闭${RESET}"

    pause
}

# ============================================================
# 判断运行状态
# ============================================================

service_running() {

    case "$SERVICE_MODE" in

        systemd)
            systemctl is-active --quiet sing-box
            ;;

        openrc)
            rc-service sing-box status >/dev/null 2>&1
            ;;

        *)
            return 1
            ;;
    esac
}

# ============================================================
# 状态
# ============================================================

show_status() {

    clear

    echo "======================================"
    echo "          sing-box 状态"
    echo "======================================"
    echo

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "状态：未配置"
        pause
        return
    fi

    load_node

    case "$protocol" in
        vless_ws)
            echo "协议：VLESS + WS + TLS"
            ;;
        vless_reality)
            echo "协议：VLESS + Reality"
            ;;
        socks5)
            echo "协议：SOCKS5"
            ;;
    esac

    echo "服务器：$server"
    echo "端口：$port"
    echo

    if service_running; then
        echo -e "运行状态：${GREEN}运行中${RESET}"
    else
        echo -e "运行状态：${RED}已停止${RESET}"
    fi

    echo

    if [ -x "$BIN" ]; then
        "$BIN" version
    fi

    pause
}

# ============================================================
# 测试出口
# ============================================================

test_proxy() {

    clear

    echo "======================================"
    echo "          测试代理出口"
    echo "======================================"
    echo

    if ! service_running; then
        echo "sing-box 当前没有运行"
        pause
        return
    fi

    echo "IPv4："

    curl -4 --max-time 10 https://api.ipify.org 2>/dev/null

    echo
    echo
    echo "IPv6："

    curl -6 --max-time 10 https://api64.ipify.org 2>/dev/null

    echo
    echo

    pause
}

# ============================================================
# 查看配置
# ============================================================

show_node() {

    clear

    echo "======================================"
    echo "          当前节点"
    echo "======================================"
    echo

    if [ ! -f "$NODE_FILE" ]; then
        echo "暂无节点"
        pause
        return
    fi

    load_node

    case "$protocol" in

        vless_ws)

            echo "协议：VLESS + WS + TLS"
            echo "服务器：$server"
            echo "端口：$port"
            echo "UUID：${uuid:0:8}********"
            echo "SNI：$sni"
            echo "WS Host：$host"
            echo "WS Path：$path"
            echo "指纹：$fp"
            ;;

        vless_reality)

            echo "协议：VLESS + Reality"
            echo "服务器：$server"
            echo "端口：$port"
            echo "UUID：${uuid:0:8}********"
            echo "SNI：$sni"
            echo "指纹：$fp"
            echo "Short ID：$sid"
            ;;

        socks5)

            echo "协议：SOCKS5"
            echo "服务器：$server"
            echo "端口：$port"

            if [ -n "$user" ]; then
                echo "用户名：已设置"
                echo "密码：已设置"
            else
                echo "认证：无"
            fi

            ;;
    esac

    pause
}

# ============================================================
# 卸载
# ============================================================

uninstall_sb() {

    clear

    echo "======================================"
    echo "          卸载 sing-box"
    echo "======================================"
    echo

    read -r -p "确定卸载？[y/N]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        return
    fi

    service_stop

    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable sing-box >/dev/null 2>&1
        systemctl daemon-reload >/dev/null 2>&1
    fi

    rm -f "$SERVICE_FILE"
    rm -f /etc/init.d/sing-box

    rm -rf "$CONFIG_DIR"

    rm -f /usr/local/bin/sing-box

    echo
    echo -e "${GREEN}sing-box 已卸载${RESET}"

    pause
}

# ============================================================
# 快捷命令
# ============================================================

install_shortcut() {

    cat > /usr/local/bin/sbout <<'EOF'
#!/bin/bash
exec bash <(curl -fsSL https://raw.githubusercontent.com/edmond1294/-/main/proxy.sh)
EOF

    chmod +x /usr/local/bin/sbout
}

# ============================================================
# 主菜单
# ============================================================

main_menu() {

    need_root
    detect_os

    if [ ! -x "$BIN" ] && ! command -v sing-box >/dev/null 2>&1; then
        install_singbox

        if [ $? -ne 0 ]; then
            echo
            echo -e "${RED}sing-box 安装失败${RESET}"
            pause
            return
        fi
    else
        if command -v sing-box >/dev/null 2>&1; then
            BIN="$(command -v sing-box)"
        fi
    fi

    install_shortcut

    if command -v systemctl >/dev/null 2>&1; then
        SERVICE_MODE="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        SERVICE_MODE="openrc"
    else
        SERVICE_MODE="none"
    fi

    while true; do

        clear

        echo "======================================"
        echo "       sing-box 全局出口管理"
        echo "======================================"
        echo
        echo "当前系统：$OS"
        echo "当前架构：$ARCH"
        echo

        if [ -f "$NODE_FILE" ]; then
            load_node

            case "$protocol" in
                vless_ws)
                    echo "当前协议：VLESS + WS + TLS"
                    ;;
                vless_reality)
                    echo "当前协议：VLESS + Reality"
                    ;;
                socks5)
                    echo "当前协议：SOCKS5"
                    ;;
                *)
                    echo "当前协议：未知"
                    ;;
            esac
        else
            echo "当前节点：未配置"
        fi

        echo

        if service_running; then
            echo "运行状态：运行中"
        else
            echo "运行状态：已停止"
        fi

        echo
        echo "--------------------------------------"
        echo "1. 选择协议并粘贴链接"
        echo "2. 开启全局代理"
        echo "3. 关闭全局代理"
        echo "4. 查看当前节点"
        echo "5. 查看运行状态"
        echo "6. 测试出口 IP"
        echo "7. 重新安装 sing-box"
        echo "8. 卸载 sing-box"
        echo "0. 退出"
        echo "--------------------------------------"
        echo

        read -r -p "请选择 [0-8]: " MENU

        case "$MENU" in

            1)
                configure_node
                ;;

            2)
                enable_proxy
                ;;

            3)
                disable_proxy
                ;;

            4)
                show_node
                ;;

            5)
                show_status
                ;;

            6)
                test_proxy
                ;;

            7)
                install_singbox
                pause
                ;;

            8)
                uninstall_sb
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
}

main_menu
