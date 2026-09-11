#!/bin/bash

# ============================================================
# sing-box 全局出口腳本
# ============================================================

set -u

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
NODE_FILE="${CONFIG_DIR}/node.txt"
BACKUP_DIR="${CONFIG_DIR}/backup"

SCRIPT_PATH="/usr/local/sbin/sbout-main.sh"
SHORTCUT="/usr/local/bin/sbout"

RAW_URL="https://raw.githubusercontent.com/edmond1294/-/main/proxy.sh"

SB_BIN=""

# ============================================================
# 基礎函數
# ============================================================

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "請使用 root 權限運行。"
        exit 1
    fi
}

detect_init() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT="openrc"
    else
        INIT="none"
    fi
}

refresh_binary() {
    SB_BIN=""

    if command -v sing-box >/dev/null 2>&1; then
        SB_BIN="$(command -v sing-box)"
        return 0
    fi

    if [ -x "/usr/local/bin/sing-box" ]; then
        SB_BIN="/usr/local/bin/sing-box"
        return 0
    fi

    if [ -x "/usr/bin/sing-box" ]; then
        SB_BIN="/usr/bin/sing-box"
        return 0
    fi

    return 1
}

pause_screen() {
    echo
    read -r -p "按 Enter 返回..." _
}

# ============================================================
# 依賴
# ============================================================

install_dependencies() {

    echo
    echo "正在安裝必要依賴..."

    if command -v apt-get >/dev/null 2>&1; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y >/dev/null 2>&1 || true

        apt-get install -y \
            curl \
            wget \
            ca-certificates \
            tar \
            gzip \
            unzip \
            python3 \
            iproute2 \
            >/dev/null 2>&1 || true

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y \
            curl \
            wget \
            ca-certificates \
            tar \
            gzip \
            unzip \
            python3 \
            iproute \
            >/dev/null 2>&1 || true

    elif command -v yum >/dev/null 2>&1; then

        yum install -y \
            curl \
            wget \
            ca-certificates \
            tar \
            gzip \
            unzip \
            python3 \
            iproute \
            >/dev/null 2>&1 || true

    elif command -v apk >/dev/null 2>&1; then

        apk add --no-cache \
            curl \
            wget \
            ca-certificates \
            tar \
            gzip \
            unzip \
            python3 \
            iproute2 \
            >/dev/null 2>&1 || true

    elif command -v pacman >/dev/null 2>&1; then

        pacman -Sy --noconfirm \
            curl \
            wget \
            ca-certificates \
            tar \
            gzip \
            unzip \
            python \
            iproute2 \
            >/dev/null 2>&1 || true
    fi
}

# ============================================================
# 架構判斷
# ============================================================

detect_arch() {

    local arch

    arch="$(uname -m)"

    case "$arch" in

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
            echo
            echo "不支援的 CPU 架構：$arch"
            return 1
            ;;
    esac

    return 0
}

# ============================================================
# GitHub 備用安裝
# ============================================================

install_from_github() {

    echo
    echo "正在使用 GitHub Release 備用安裝..."

    if ! command -v curl >/dev/null 2>&1; then
        echo "找不到 curl，無法使用 GitHub 備用安裝。"
        return 1
    fi

    detect_arch || return 1

    local version
    local tag
    local url
    local tmp
    local archive
    local extract_dir

    version="$(
        curl -fsSL \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        2>/dev/null |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' |
        head -n 1
    )"

    if [ -z "$version" ]; then
        echo "無法取得 GitHub 最新版本。"
        return 1
    fi

    tag="${version#v}"

    tmp="/tmp/sing-box-install"
    archive="${tmp}/sing-box.tar.gz"
    extract_dir="${tmp}/extract"

    rm -rf "$tmp"
    mkdir -p "$extract_dir"

    url="https://github.com/SagerNet/sing-box/releases/download/${version}/sing-box-${tag}-linux-${SB_ARCH}.tar.gz"

    echo
    echo "版本：$version"
    echo "架構：$SB_ARCH"
    echo

    if ! curl -fL \
        --connect-timeout 15 \
        --retry 3 \
        "$url" \
        -o "$archive"; then

        echo
        echo "GitHub Release 下載失敗。"
        echo "下載地址："
        echo "$url"
        return 1
    fi

    echo
    echo "正在解壓..."

    if ! tar -xzf "$archive" -C "$extract_dir"; then
        echo "解壓失敗。"
        return 1
    fi

    local found

    found="$(
        find "$extract_dir" \
            -type f \
            -name "sing-box" \
            -perm -u+x \
            2>/dev/null |
        head -n 1
    )"

    if [ -z "$found" ]; then
        echo "找不到 sing-box 執行文件。"
        return 1
    fi

    install -m 0755 "$found" /usr/local/bin/sing-box

    rm -rf "$tmp"

    refresh_binary

    if [ -z "$SB_BIN" ]; then
        echo "GitHub 備用安裝失敗。"
        return 1
    fi

    echo
    echo "GitHub Release 安裝成功。"
    "$SB_BIN" version 2>/dev/null || true

    return 0
}

# ============================================================
# 官方安裝
# ============================================================

install_from_official() {

    echo
    echo "正在使用官方安裝方式..."

    if ! command -v curl >/dev/null 2>&1; then
        echo "找不到 curl。"
        return 1
    fi

    if curl -fsSL \
        --connect-timeout 15 \
        --retry 2 \
        https://sing-box.app/install.sh |
        sh; then

        refresh_binary

        if [ -n "$SB_BIN" ]; then
            echo
            echo "官方安裝成功。"
            "$SB_BIN" version 2>/dev/null || true
            return 0
        fi
    fi

    echo
    echo "官方安裝失敗。"

    return 1
}

# ============================================================
# 安裝 sing-box
# ============================================================

install_singbox() {

    install_dependencies

    refresh_binary

    if [ -n "$SB_BIN" ]; then

        echo
        echo "已檢測到 sing-box："
        "$SB_BIN" version 2>/dev/null || true
        echo

        create_service

        return 0
    fi

    if ! install_from_official; then

        echo
        echo "切換 GitHub Release 備用安裝..."
        echo

        if ! install_from_github; then

            echo
            echo "========================================"
            echo "sing-box 安裝失敗"
            echo "========================================"
            echo
            echo "請檢查："
            echo "1. VPS 是否可以訪問 GitHub"
            echo "2. VPS 是否可以訪問 sing-box.app"
            echo "3. CPU 架構是否受支援"
            echo

            return 1
        fi
    fi

    refresh_binary

    if [ -z "$SB_BIN" ]; then
        echo
        echo "找不到 sing-box 執行文件。"
        return 1
    fi

    create_service

    return 0
}

# ============================================================
# systemd / OpenRC
# ============================================================

create_service() {

    refresh_binary

    [ -z "$SB_BIN" ] && return 1

    mkdir -p "$CONFIG_DIR"

    if [ "$INIT" = "systemd" ]; then

        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Global Proxy
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SB_BIN} run -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload

    elif [ "$INIT" = "openrc" ]; then

        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box Global Proxy"

command="${SB_BIN}"
command_args="run -c ${CONFIG_FILE}"

command_background="yes"
pidfile="/run/sing-box.pid"

depend() {
    need net
}
EOF

        chmod +x /etc/init.d/sing-box
    fi
}

service_stop() {

    if [ "$INIT" = "systemd" ]; then

        systemctl stop sing-box >/dev/null 2>&1 || true

    elif [ "$INIT" = "openrc" ]; then

        rc-service sing-box stop >/dev/null 2>&1 || true

    else

        pkill -x sing-box >/dev/null 2>&1 || true
    fi
}

service_start() {

    if [ "$INIT" = "systemd" ]; then

        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1 || true
        systemctl restart sing-box

        sleep 2

        systemctl is-active --quiet sing-box

    elif [ "$INIT" = "openrc" ]; then

        rc-update add sing-box default >/dev/null 2>&1 || true
        rc-service sing-box restart

        sleep 2

        rc-service sing-box status >/dev/null 2>&1

    else

        nohup "$SB_BIN" run -c "$CONFIG_FILE" \
            >/var/log/sing-box.log 2>&1 &

        sleep 2

        pgrep -x sing-box >/dev/null 2>&1
    fi
}

# ============================================================
# URL 解碼
# ============================================================

url_decode() {

    local value="$1"

    if command -v python3 >/dev/null 2>&1; then

        python3 - "$value" <<'PY'
import sys
from urllib.parse import unquote

print(unquote(sys.argv[1]))
PY

    else

        printf '%b' "${value//%/\\x}"

    fi
}

# ============================================================
# 主機 / 端口
# ============================================================

parse_host_port() {

    local hp="$1"

    if [[ "$hp" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then

        SERVER="${BASH_REMATCH[1]}"
        PORT="${BASH_REMATCH[2]}"

    else

        SERVER="${hp%:*}"
        PORT="${hp##*:}"

    fi

    if [ -z "$SERVER" ] || [ -z "$PORT" ]; then
        return 1
    fi

    return 0
}

# ============================================================
# VLESS WS TLS
# ============================================================

parse_vless_ws() {

    local url="$1"

    if [[ "$url" != vless://* ]]; then
        echo
        echo "錯誤：這不是 VLESS 鏈接。"
        return 1
    fi

    local body
    local main
    local query

    body="${url#vless://}"
    body="${body%%#*}"

    main="${body%%\?*}"
    query=""

    if [[ "$body" == *"?"* ]]; then
        query="${body#*\?}"
    fi

    UUID="${main%@*}"
    HOSTPORT="${main#*@}"

    if [ -z "$UUID" ] || [ -z "$HOSTPORT" ]; then
        echo
        echo "錯誤：VLESS 鏈接格式不正確。"
        return 1
    fi

    if ! parse_host_port "$HOSTPORT"; then
        echo
        echo "錯誤：服務器地址格式不正確。"
        return 1
    fi

    NETWORK=""
    SECURITY=""
    SNI=""
    FP=""
    HOST=""
    PATH=""
    FLOW=""

    if [ -n "$query" ]; then

        IFS='&' read -ra PARAMS <<< "$query"

        for item in "${PARAMS[@]}"; do

            key="${item%%=*}"
            value="${item#*=}"

            value="$(url_decode "$value")"

            case "$key" in

                type)
                    NETWORK="$value"
                    ;;

                security)
                    SECURITY="$value"
                    ;;

                sni)
                    SNI="$value"
                    ;;

                fp)
                    FP="$value"
                    ;;

                host)
                    HOST="$value"
                    ;;

                path)
                    PATH="$value"
                    ;;

                flow)
                    FLOW="$value"
                    ;;

            esac
        done
    fi

    if [ "$NETWORK" != "ws" ]; then
        echo
        echo "錯誤：你選擇的是 VLESS + WS + TLS。"
        echo "鏈接中的 type 必須是 ws。"
        return 1
    fi

    if [ "$SECURITY" != "tls" ]; then
        echo
        echo "錯誤：你選擇的是 VLESS + WS + TLS。"
        echo "鏈接中的 security 必須是 tls。"
        return 1
    fi

    [ -z "$SNI" ] && SNI="$SERVER"
    [ -z "$FP" ] && FP="chrome"
    [ -z "$HOST" ] && HOST="$SNI"
    [ -z "$PATH" ] && PATH="/"

    NODE_TYPE="vless_ws"

    save_node

    generate_config
}

# ============================================================
# VLESS Reality
# ============================================================

parse_vless_reality() {

    local url="$1"

    if [[ "$url" != vless://* ]]; then
        echo
        echo "錯誤：這不是 VLESS 鏈接。"
        return 1
    fi

    local body
    local main
    local query

    body="${url#vless://}"
    body="${body%%#*}"

    main="${body%%\?*}"
    query=""

    if [[ "$body" == *"?"* ]]; then
        query="${body#*\?}"
    fi

    UUID="${main%@*}"
    HOSTPORT="${main#*@}"

    if [ -z "$UUID" ] || [ -z "$HOSTPORT" ]; then
        echo
        echo "錯誤：VLESS 鏈接格式不正確。"
        return 1
    fi

    if ! parse_host_port "$HOSTPORT"; then
        echo
        echo "錯誤：服務器地址格式不正確。"
        return 1
    fi

    NETWORK=""
    SECURITY=""
    SNI=""
    FP=""
    PBK=""
    SID=""
    FLOW=""

    if [ -n "$query" ]; then

        IFS='&' read -ra PARAMS <<< "$query"

        for item in "${PARAMS[@]}"; do

            key="${item%%=*}"
            value="${item#*=}"

            value="$(url_decode "$value")"

            case "$key" in

                type)
                    NETWORK="$value"
                    ;;

                security)
                    SECURITY="$value"
                    ;;

                sni)
                    SNI="$value"
                    ;;

                fp)
                    FP="$value"
                    ;;

                pbk)
                    PBK="$value"
                    ;;

                sid)
                    SID="$value"
                    ;;

                flow)
                    FLOW="$value"
                    ;;

            esac
        done
    fi

    if [ "$SECURITY" != "reality" ]; then
        echo
        echo "錯誤：你選擇的是 VLESS Reality。"
        echo "鏈接中的 security 必須是 reality。"
        return 1
    fi

    if [ -z "$PBK" ]; then
        echo
        echo "錯誤：Reality 鏈接缺少 pbk。"
        return 1
    fi

    [ -z "$SNI" ] && SNI="$SERVER"
    [ -z "$FP" ] && FP="chrome"

    NODE_TYPE="vless_reality"

    save_node

    generate_config
}

# ============================================================
# SOCKS5
# ============================================================

parse_socks5() {

    local url="$1"

    if [[ "$url" != socks5://* && "$url" != socks://* ]]; then
        echo
        echo "錯誤：這不是 SOCKS5 鏈接。"
        return 1
    fi

    local body
    local auth_host

    if [[ "$url" == socks5://* ]]; then
        body="${url#socks5://}"
    else
        body="${url#socks://}"
    fi

    body="${body%%#*}"

    auth_host="${body%%\?*}"

    USER=""
    PASS=""

    if [[ "$auth_host" == *"@"* ]]; then

        local auth

        auth="${auth_host%@*}"
        HOSTPORT="${auth_host#*@}"

        USER="${auth%%:*}"
        PASS="${auth#*:}"

        USER="$(url_decode "$USER")"
        PASS="$(url_decode "$PASS")"

    else

        HOSTPORT="$auth_host"

    fi

    if ! parse_host_port "$HOSTPORT"; then
        echo
        echo "錯誤：SOCKS5 地址格式不正確。"
        return 1
    fi

    NODE_TYPE="socks5"

    save_node

    generate_config
}

# ============================================================
# 保存節點
# ============================================================

save_node() {

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    cat > "$NODE_FILE" <<EOF
TYPE=$NODE_TYPE
SERVER=$SERVER
PORT=$PORT
UUID=${UUID:-}
SNI=${SNI:-}
FP=${FP:-}
HOST=${HOST:-}
PATH=${PATH:-}
PBK=${PBK:-}
SID=${SID:-}
FLOW=${FLOW:-}
USER=${USER:-}
PASS=${PASS:-}
EOF

    chmod 600 "$NODE_FILE"
}

# ============================================================
# 讀取節點
# ============================================================

load_node() {

    if [ ! -f "$NODE_FILE" ]; then
        return 1
    fi

    unset TYPE
    unset SERVER
    unset PORT
    unset UUID
    unset SNI
    unset FP
    unset HOST
    unset PATH
    unset PBK
    unset SID
    unset FLOW
    unset USER
    unset PASS

    # shellcheck disable=SC1090
    source "$NODE_FILE"

    return 0
}

# ============================================================
# 生成 VLESS WS TLS
# ============================================================

generate_vless_ws() {

    cat > "$CONFIG_FILE" <<EOF
{
  "\$schema": "https://sing-box.sagernet.org/schema.json",

  "log": {
    "level": "info"
  },

  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-remote",
        "server": "1.1.1.1",
        "server_port": 53,
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
      "server": "$SERVER",
      "server_port": $PORT,
      "uuid": "$UUID",
      "network": "ws",

      "tls": {
        "enabled": true,
        "server_name": "$SNI",

        "utls": {
          "enabled": true,
          "fingerprint": "$FP"
        }
      },

      "transport": {
        "type": "ws",
        "path": "$PATH",

        "headers": {
          "Host": "$HOST"
        }
      }
    },

    {
      "type": "direct",
      "tag": "direct"
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
}

# ============================================================
# 生成 VLESS Reality
# ============================================================

generate_vless_reality() {

    local flow_line=""

    if [ -n "${FLOW:-}" ]; then
        flow_line="      \"flow\": \"$FLOW\","
    fi

    cat > "$CONFIG_FILE" <<EOF
{
  "\$schema": "https://sing-box.sagernet.org/schema.json",

  "log": {
    "level": "info"
  },

  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-remote",
        "server": "1.1.1.1",
        "server_port": 53,
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
      "server": "$SERVER",
      "server_port": $PORT,
      "uuid": "$UUID",
$flow_line      "network": "tcp",

      "tls": {
        "enabled": true,
        "server_name": "$SNI",

        "utls": {
          "enabled": true,
          "fingerprint": "$FP"
        },

        "reality": {
          "enabled": true,
          "public_key": "$PBK",
          "short_id": "$SID"
        }
      }
    },

    {
      "type": "direct",
      "tag": "direct"
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

    if [ -z "${FLOW:-}" ]; then
        sed -i '/^[[:space:]]*"flow":/d' "$CONFIG_FILE"
    fi
}

# ============================================================
# 生成 SOCKS5
# ============================================================

generate_socks5() {

    if [ -n "${USER:-}" ]; then

        cat > "$CONFIG_FILE" <<EOF
{
  "\$schema": "https://sing-box.sagernet.org/schema.json",

  "log": {
    "level": "info"
  },

  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-remote",
        "server": "1.1.1.1",
        "server_port": 53,
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
      "server": "$SERVER",
      "server_port": $PORT,
      "version": "5",
      "username": "$USER",
      "password": "$PASS"
    },

    {
      "type": "direct",
      "tag": "direct"
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

    else

        cat > "$CONFIG_FILE" <<EOF
{
  "\$schema": "https://sing-box.sagernet.org/schema.json",

  "log": {
    "level": "info"
  },

  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-remote",
        "server": "1.1.1.1",
        "server_port": 53,
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
      "server": "$SERVER",
      "server_port": $PORT,
      "version": "5"
    },

    {
      "type": "direct",
      "tag": "direct"
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

    fi
}

# ============================================================
# 生成配置
# ============================================================

generate_config() {

    mkdir -p "$CONFIG_DIR"
    mkdir -p "$BACKUP_DIR"

    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" \
            "$BACKUP_DIR/config.$(date +%Y%m%d%H%M%S).json"
    fi

    case "$NODE_TYPE" in

        vless_ws)
            generate_vless_ws
            ;;

        vless_reality)
            generate_vless_reality
            ;;

        socks5)
            generate_socks5
            ;;

        *)
            echo
            echo "未知節點類型。"
            return 1
            ;;
    esac

    chmod 600 "$CONFIG_FILE"

    refresh_binary

    if [ -z "$SB_BIN" ]; then
        echo
        echo "找不到 sing-box。"
        return 1
    fi

    echo
    echo "正在檢查配置..."

    if "$SB_BIN" check -c "$CONFIG_FILE"; then

        echo
        echo "配置檢查通過。"
        echo

        create_service

        return 0

    else

        echo
        echo "配置檢查失敗。"
        echo
        echo "配置文件：$CONFIG_FILE"
        echo

        return 1
    fi
}

# ============================================================
# 配置節點
# ============================================================

configure_node() {

    while true; do

        clear

        echo "========================================"
        echo "             選擇代理協議"
        echo "========================================"
        echo
        echo "1. VLESS + WS + TLS"
        echo "2. VLESS + Reality"
        echo "3. SOCKS5"
        echo "0. 返回"
        echo

        read -r -p "請選擇: " choice

        case "$choice" in

            1)

                echo
                echo "請貼上 VLESS + WS + TLS 鏈接："
                echo

                read -r -p "> " LINK

                if parse_vless_ws "$LINK"; then
                    echo
                    echo "節點配置成功。"
                    pause_screen
                    return
                fi

                pause_screen
                ;;

            2)

                echo
                echo "請貼上 VLESS Reality 鏈接："
                echo

                read -r -p "> " LINK

                if parse_vless_reality "$LINK"; then
                    echo
                    echo "節點配置成功。"
                    pause_screen
                    return
                fi

                pause_screen
                ;;

            3)

                echo
                echo "請貼上 SOCKS5 鏈接："
                echo

                read -r -p "> " LINK

                if parse_socks5 "$LINK"; then
                    echo
                    echo "節點配置成功。"
                    pause_screen
                    return
                fi

                pause_screen
                ;;

            0)
                return
                ;;

            *)
                echo
                echo "無效選項。"
                sleep 1
                ;;

        esac
    done
}

# ============================================================
# 查看節點
# ============================================================

show_node() {

    if ! load_node; then

        echo
        echo "目前沒有配置節點。"
        return
    fi

    echo
    echo "========================================"
    echo "             目前節點"
    echo "========================================"
    echo

    case "$TYPE" in

        vless_ws)
            echo "協議：VLESS + WS + TLS"
            ;;

        vless_reality)
            echo "協議：VLESS + Reality"
            ;;

        socks5)
            echo "協議：SOCKS5"
            ;;

        *)
            echo "協議：未知"
            ;;
    esac

    echo "服務器：$SERVER"
    echo "端口：$PORT"

    if [ "$TYPE" = "vless_ws" ]; then

        echo "SNI：$SNI"
        echo "Host：$HOST"
        echo "Path：$PATH"
        echo "指紋：$FP"

    elif [ "$TYPE" = "vless_reality" ]; then

        echo "SNI：$SNI"
        echo "指紋：$FP"
        echo "Short ID：$SID"

        if [ -n "${FLOW:-}" ]; then
            echo "Flow：$FLOW"
        fi

    elif [ "$TYPE" = "socks5" ]; then

        if [ -n "${USER:-}" ]; then
            echo "認證：已配置"
        else
            echo "認證：無"
        fi

    fi

    echo
}

# ============================================================
# 開啟全局
# ============================================================

enable_proxy() {

    if [ ! -f "$CONFIG_FILE" ]; then

        echo
        echo "尚未配置節點。"
        echo "請先進入「1. 選擇協議並貼上鏈接」。"
        pause_screen
        return
    fi

    refresh_binary

    if [ -z "$SB_BIN" ]; then

        echo
        echo "尚未安裝 sing-box。"
        echo "正在重新安裝..."
        echo

        if ! install_singbox; then
            pause_screen
            return
        fi
    fi

    echo
    echo "正在檢查配置..."

    if ! "$SB_BIN" check -c "$CONFIG_FILE"; then

        echo
        echo "配置檢查失敗。"
        pause_screen
        return
    fi

    service_stop

    echo
    echo "正在啟動全局代理..."

    if service_start; then

        echo
        echo "全局代理已開啟。"

    else

        echo
        echo "sing-box 啟動失敗。"
        echo

        if [ "$INIT" = "systemd" ]; then

            journalctl \
                -u sing-box \
                --no-pager \
                -n 30 \
                2>/dev/null || true

        elif [ -f /var/log/sing-box.log ]; then

            tail -n 30 /var/log/sing-box.log

        fi
    fi

    pause_screen
}

# ============================================================
# 關閉全局
# ============================================================

disable_proxy() {

    service_stop

    echo
    echo "全局代理已關閉。"

    pause_screen
}

# ============================================================
# 狀態
# ============================================================

show_status() {

    echo

    if [ "$INIT" = "systemd" ]; then

        systemctl status \
            sing-box \
            --no-pager \
            2>/dev/null || true

    elif [ "$INIT" = "openrc" ]; then

        rc-service sing-box status \
            2>/dev/null || true

    else

        if pgrep -x sing-box >/dev/null 2>&1; then
            echo "sing-box：運行中"
        else
            echo "sing-box：未運行"
        fi

    fi

    echo

    if ip link show singtun0 >/dev/null 2>&1; then
        echo "TUN：singtun0 已建立"
    else
        echo "TUN：未建立"
    fi

    pause_screen
}

# ============================================================
# 測試出口
# ============================================================

test_ip() {

    echo
    echo "正在測試 IPv4 出口..."
    echo

    if command -v curl >/dev/null 2>&1; then

        curl \
            -4 \
            --connect-timeout 10 \
            -fsSL \
            https://api.ipify.org \
            2>/dev/null || true

        echo

    fi

    echo
    echo "正在測試 IPv6 出口..."
    echo

    if command -v curl >/dev/null 2>&1; then

        curl \
            -6 \
            --connect-timeout 10 \
            -fsSL \
            https://api64.ipify.org \
            2>/dev/null || true

        echo

    fi

    pause_screen
}

# ============================================================
# 安裝快捷命令
# ============================================================

install_shortcut() {

    mkdir -p /usr/local/sbin

    cp "$0" "$SCRIPT_PATH" 2>/dev/null || true

    chmod +x "$SCRIPT_PATH" 2>/dev/null || true

    cat > "$SHORTCUT" <<EOF
#!/bin/bash
exec "$SCRIPT_PATH" "\$@"
EOF

    chmod +x "$SHORTCUT"
}

# ============================================================
# 更新腳本
# ============================================================

update_script() {

    install_dependencies

    echo
    echo "正在從 GitHub 更新腳本..."
    echo

    local tmp="/tmp/sbout-update.sh"

    if curl -fsSL \
        --connect-timeout 15 \
        --retry 3 \
        "$RAW_URL" \
        -o "$tmp"; then

        chmod +x "$tmp"

        cp "$tmp" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"

        rm -f "$tmp"

        echo
        echo "腳本更新完成。"

    else

        echo
        echo "GitHub 更新失敗。"
    fi

    pause_screen
}

# ============================================================
# 重新安裝
# ============================================================

reinstall_singbox() {

    echo
    echo "正在重新安裝 sing-box..."
    echo

    service_stop

    rm -f /usr/local/bin/sing-box

    if ! install_singbox; then

        echo
        echo "重新安裝失敗。"

    else

        echo
        echo "重新安裝完成。"
    fi

    pause_screen
}

# ============================================================
# 卸載
# ============================================================

uninstall_all() {

    echo
    echo "這將刪除 sing-box、配置及 sbout。"
    echo

    read -r -p "確定卸載？輸入 YES： " confirm

    if [ "$confirm" != "YES" ]; then

        echo
        echo "已取消。"
        pause_screen
        return
    fi

    service_stop

    if [ "$INIT" = "systemd" ]; then

        systemctl disable sing-box \
            >/dev/null 2>&1 || true

        rm -f /etc/systemd/system/sing-box.service

        systemctl daemon-reload

    elif [ "$INIT" = "openrc" ]; then

        rc-update del sing-box default \
            >/dev/null 2>&1 || true

        rm -f /etc/init.d/sing-box

    fi

    rm -rf "$CONFIG_DIR"

    rm -f /usr/local/bin/sing-box
    rm -f "$SHORTCUT"
    rm -f "$SCRIPT_PATH"

    echo
    echo "卸載完成。"
    echo

    exit 0
}

# ============================================================
# 主菜單
# ============================================================

main_menu() {

    while true; do

        clear

        echo "========================================"
        echo "          sing-box 全局出口"
        echo "========================================"
        echo

        if [ -f "$NODE_FILE" ]; then
            echo "節點：已配置"
        else
            echo "節點：未配置"
        fi

        if [ "$INIT" = "systemd" ]; then

            if systemctl is-active --quiet sing-box 2>/dev/null; then
                echo "狀態：運行中"
            else
                echo "狀態：已停止"
            fi

        elif [ "$INIT" = "openrc" ]; then

            if rc-service sing-box status >/dev/null 2>&1; then
                echo "狀態：運行中"
            else
                echo "狀態：已停止"
            fi

        else

            if pgrep -x sing-box >/dev/null 2>&1; then
                echo "狀態：運行中"
            else
                echo "狀態：已停止"
            fi

        fi

        echo
        echo "----------------------------------------"
        echo "1. 選擇協議並貼上鏈接"
        echo "2. 開啟全局代理"
        echo "3. 關閉全局代理"
        echo "4. 查看目前節點"
        echo "5. 查看運行狀態"
        echo "6. 測試出口 IP"
        echo "7. 重新安裝 sing-box"
        echo "8. 更新 sbout 腳本"
        echo "9. 卸載 sing-box"
        echo "0. 退出"
        echo "----------------------------------------"
        echo

        read -r -p "請選擇: " choice

        case "$choice" in

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
                pause_screen
                ;;

            5)
                show_status
                ;;

            6)
                test_ip
                ;;

            7)
                reinstall_singbox
                ;;

            8)
                update_script
                ;;

            9)
                uninstall_all
                ;;

            0)
                exit 0
                ;;

            *)
                echo
                echo "無效選項。"
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# 主程序
# ============================================================

main_app() {

    check_root

    detect_init

    mkdir -p "$CONFIG_DIR"

    # 安裝 sbout 自身
    install_shortcut

    # 檢查 sing-box
    refresh_binary

    if [ -z "$SB_BIN" ]; then

        echo
        echo "首次運行，正在安裝 sing-box..."
        echo

        if ! install_singbox; then

            echo
            echo "========================================"
            echo "sing-box 安裝失敗"
            echo "========================================"
            echo
            echo "官方安裝和 GitHub 備用安裝均失敗。"
            echo

            pause_screen
            exit 1
        fi
    fi

    # 建立服務
    create_service

    # 正常進入主菜單
    main_menu
}

# ============================================================
# 啟動
# ============================================================

main_app
