#!/bin/bash

# ==========================================
# sing-box 全局出口腳本
# 支持：
# 1. VLESS + WS + TLS
# 2. VLESS + Reality
# 3. SOCKS5
#
# 快捷命令：
# sbout
# ==========================================

set -u

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
NODE_FILE="${CONFIG_DIR}/node.txt"
BACKUP_DIR="${CONFIG_DIR}/backup"

SB_BIN="$(command -v sing-box 2>/dev/null || true)"

RAW_URL="https://raw.githubusercontent.com/edmond1294/-/main/proxy.sh"

# ------------------------------------------
# 基礎
# ------------------------------------------

pause() {
    echo
    read -r -p "按 Enter 返回..."
}

die() {
    echo
    echo "錯誤：$1"
    echo
    pause
    return 1
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "請使用 root 運行。"
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
    SB_BIN="$(command -v sing-box 2>/dev/null || true)"

    if [ -z "$SB_BIN" ] && [ -x /usr/local/bin/sing-box ]; then
        SB_BIN="/usr/local/bin/sing-box"
    fi
}

# ------------------------------------------
# 安裝依賴
# ------------------------------------------

install_dependencies() {

    if command -v apt-get >/dev/null 2>&1; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y >/dev/null 2>&1 || true

        apt-get install -y \
            curl \
            wget \
            ca-certificates \
            unzip \
            tar \
            python3 \
            iproute2 \
            >/dev/null 2>&1 || true

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y \
            curl \
            wget \
            ca-certificates \
            unzip \
            tar \
            python3 \
            iproute \
            >/dev/null 2>&1 || true

    elif command -v yum >/dev/null 2>&1; then

        yum install -y \
            curl \
            wget \
            ca-certificates \
            unzip \
            tar \
            python3 \
            iproute \
            >/dev/null 2>&1 || true

    elif command -v apk >/dev/null 2>&1; then

        apk add --no-cache \
            curl \
            wget \
            ca-certificates \
            unzip \
            tar \
            python3 \
            iproute2 \
            >/dev/null 2>&1 || true

    elif command -v pacman >/dev/null 2>&1; then

        pacman -Sy --noconfirm \
            curl \
            wget \
            ca-certificates \
            unzip \
            tar \
            python \
            iproute2 \
            >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------
# 安裝 sing-box
# ------------------------------------------

install_singbox() {

    check_root

    echo
    echo "正在安裝最新版 sing-box..."
    echo

    install_dependencies

    if command -v curl >/dev/null 2>&1; then

        if curl -fsSL https://sing-box.app/install.sh | sh; then
            :
        else
            echo "官方安裝腳本失敗。"
        fi

    else
        echo "找不到 curl。"
    fi

    refresh_binary

    if [ -z "$SB_BIN" ]; then
        echo
        echo "sing-box 安裝失敗。"
        echo
        pause
        return 1
    fi

    echo
    echo "sing-box 安裝完成。"
    "$SB_BIN" version 2>/dev/null || true
    echo

    create_service

    pause
}

# ------------------------------------------
# 建立服務
# ------------------------------------------

create_service() {

    refresh_binary

    mkdir -p "$CONFIG_DIR"

    if [ "$INIT" = "systemd" ]; then

        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Global Proxy
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

# ------------------------------------------
# 服務控制
# ------------------------------------------

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
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box

        sleep 2

        if systemctl is-active --quiet sing-box; then
            return 0
        fi

        return 1

    elif [ "$INIT" = "openrc" ]; then

        rc-update add sing-box default >/dev/null 2>&1 || true
        rc-service sing-box restart

        sleep 2

        if rc-service sing-box status >/dev/null 2>&1; then
            return 0
        fi

        return 1

    else

        nohup "$SB_BIN" run -c "$CONFIG_FILE" \
            >/var/log/sing-box.log 2>&1 &

        sleep 2

        if pgrep -x sing-box >/dev/null 2>&1; then
            return 0
        fi

        return 1
    fi
}

service_restart() {

    service_stop
    sleep 1

    if service_start; then
        echo "全局代理已啟動。"
        return 0
    fi

    echo
    echo "sing-box 啟動失敗。"
    echo

    if [ "$INIT" = "systemd" ]; then
        journalctl -u sing-box --no-pager -n 40 2>/dev/null || true
    elif [ -f /var/log/sing-box.log ]; then
        tail -n 40 /var/log/sing-box.log
    fi

    return 1
}

# ------------------------------------------
# URL Decode
# ------------------------------------------

url_decode() {

    local value="$1"

    python3 - "$value" <<'PY'
import sys
from urllib.parse import unquote

print(unquote(sys.argv[1]))
PY
}

# ------------------------------------------
# 解析主機與端口
# ------------------------------------------

parse_host_port() {

    local hp="$1"

    if [[ "$hp" =~ ^\[([0-9a-fA-F:]+)\]:([0-9]+)$ ]]; then
        SERVER="${BASH_REMATCH[1]}"
        PORT="${BASH_REMATCH[2]}"
        return
    fi

    SERVER="${hp%:*}"
    PORT="${hp##*:}"
}

# ------------------------------------------
# 生成 VLESS WS TLS
# ------------------------------------------

parse_vless_ws() {

    local url="$1"

    if [[ "$url" != vless://* ]]; then
        echo
        echo "這不是 VLESS 鏈接。"
        return 1
    fi

    local body="${url#vless://}"

    body="${body%%#*}"

    local main="${body%%\?*}"
    local query=""

    if [[ "$body" == *"?"* ]]; then
        query="${body#*\?}"
    fi

    UUID="${main%@*}"
    HOSTPORT="${main#*@}"

    if [ -z "$UUID" ] || [ -z "$HOSTPORT" ]; then
        echo "VLESS 鏈接格式錯誤。"
        return 1
    fi

    parse_host_port "$HOSTPORT"

    NETWORK=""
    SECURITY=""
    SNI=""
    FP=""
    HOST=""
    PATH=""
    FLOW=""

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

    if [ "$NETWORK" != "ws" ]; then
        echo
        echo "你選擇的是 VLESS + WS + TLS。"
        echo "鏈接中的 type 不是 ws。"
        return 1
    fi

    if [ "$SECURITY" != "tls" ]; then
        echo
        echo "你選擇的是 VLESS + WS + TLS。"
        echo "鏈接中的 security 不是 tls。"
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

# ------------------------------------------
# 解析 VLESS Reality
# ------------------------------------------

parse_vless_reality() {

    local url="$1"

    if [[ "$url" != vless://* ]]; then
        echo
        echo "這不是 VLESS 鏈接。"
        return 1
    fi

    local body="${url#vless://}"

    body="${body%%#*}"

    local main="${body%%\?*}"
    local query=""

    if [[ "$body" == *"?"* ]]; then
        query="${body#*\?}"
    fi

    UUID="${main%@*}"
    HOSTPORT="${main#*@}"

    if [ -z "$UUID" ] || [ -z "$HOSTPORT" ]; then
        echo "VLESS 鏈接格式錯誤。"
        return 1
    fi

    parse_host_port "$HOSTPORT"

    NETWORK=""
    SECURITY=""
    SNI=""
    FP=""
    PBK=""
    SID=""
    FLOW=""

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

    if [ "$SECURITY" != "reality" ]; then
        echo
        echo "你選擇的是 VLESS Reality。"
        echo "鏈接中的 security 不是 reality。"
        return 1
    fi

    [ -z "$SNI" ] && SNI="$SERVER"
    [ -z "$FP" ] && FP="chrome"

    if [ -z "$PBK" ]; then
        echo
        echo "Reality 鏈接缺少 pbk。"
        return 1
    fi

    NODE_TYPE="vless_reality"

    save_node

    generate_config
}

# ------------------------------------------
# 解析 SOCKS5
# ------------------------------------------

parse_socks5() {

    local url="$1"

    if [[ "$url" != socks5://* && "$url" != socks://* ]]; then
        echo
        echo "這不是 SOCKS5 鏈接。"
        return 1
    fi

    local body

    if [[ "$url" == socks5://* ]]; then
        body="${url#socks5://}"
    else
        body="${url#socks://}"
    fi

    body="${body%%#*}"

    local auth_host="${body%%\?*}"

    if [[ "$auth_host" == *"@"* ]]; then

        local auth="${auth_host%@*}"
        HOSTPORT="${auth_host#*@}"

        USER="${auth%%:*}"
        PASS="${auth#*:}"

        USER="$(url_decode "$USER")"
        PASS="$(url_decode "$PASS")"

    else

        HOSTPORT="$auth_host"
        USER=""
        PASS=""

    fi

    parse_host_port "$HOSTPORT"

    if [ -z "$SERVER" ] || [ -z "$PORT" ]; then
        echo "SOCKS5 鏈接格式錯誤。"
        return 1
    fi

    NODE_TYPE="socks5"

    save_node

    generate_config
}

# ------------------------------------------
# 保存節點
# ------------------------------------------

save_node() {

    mkdir -p "$CONFIG_DIR"

    chmod 700 "$CONFIG_DIR"

    cat > "$NODE_FILE" <<EOF
TYPE=$NODE_TYPE
SERVER=$SERVER
PORT=$PORT
UUID=$UUID
SNI=$SNI
FP=$FP
HOST=$HOST
PATH=$PATH
PBK=$PBK
SID=$SID
FLOW=$FLOW
USER=$USER
PASS=$PASS
EOF

    chmod 600 "$NODE_FILE"
}

# ------------------------------------------
# 讀取節點
# ------------------------------------------

load_node() {

    if [ ! -f "$NODE_FILE" ]; then
        return 1
    fi

    unset TYPE SERVER PORT UUID SNI FP HOST PATH PBK SID FLOW USER PASS

    # shellcheck disable=SC1090
    source "$NODE_FILE"

    return 0
}

# ------------------------------------------
# 生成 DNS
# ------------------------------------------

generate_dns() {

    cat <<'EOF'
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
EOF
}

# ------------------------------------------
# 生成 VLESS WS
# ------------------------------------------

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

# ------------------------------------------
# 生成 VLESS Reality
# ------------------------------------------

generate_vless_reality() {

    local flow_line=""

    if [ -n "${FLOW:-}" ]; then
        flow_line="\"flow\": \"$FLOW\","
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
      $flow_line
      "network": "tcp",

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

    # 如果沒有 flow，刪除多餘逗號造成的空字段
    if [ -z "${FLOW:-}" ]; then
        sed -i '/^[[:space:]]*,[[:space:]]*$/d' "$CONFIG_FILE"
    fi
}

# ------------------------------------------
# 生成 SOCKS5
# ------------------------------------------

generate_socks5() {

    if [ -n "${USER:-}" ]; then

        AUTH_BLOCK=$(cat <<EOF
      "username": "$USER",
      "password": "$PASS",
EOF
)

    else

        AUTH_BLOCK=""

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
      "type": "socks",
      "tag": "proxy-out",
      "server": "$SERVER",
      "server_port": $PORT,
$AUTH_BLOCK      "version": "5"
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

# ------------------------------------------
# 生成配置
# ------------------------------------------

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

    else

        echo
        echo "配置檢查失敗。"
        echo
        echo "配置文件：$CONFIG_FILE"
        echo

        return 1
    fi

    return 0
}

# ------------------------------------------
# 選擇協議
# ------------------------------------------

configure_node() {

    while true; do

        clear

        echo "========================================"
        echo "          選擇代理協議"
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
                    echo
                    show_node
                    pause
                    return 0
                fi

                pause
                ;;

            2)

                echo
                echo "請貼上 VLESS Reality 鏈接："
                echo
                read -r -p "> " LINK

                if parse_vless_reality "$LINK"; then
                    echo
                    echo "節點配置成功。"
                    echo
                    show_node
                    pause
                    return 0
                fi

                pause
                ;;

            3)

                echo
                echo "請貼上 SOCKS5 鏈接："
                echo
                read -r -p "> " LINK

                if parse_socks5 "$LINK"; then
                    echo
                    echo "節點配置成功。"
                    echo
                    show_node
                    pause
                    return 0
                fi

                pause
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

# ------------------------------------------
# 顯示節點
# ------------------------------------------

show_node() {

    if ! load_node; then
        echo
        echo "目前沒有配置節點。"
        return
    fi

    echo
    echo "目前節點"
    echo "----------------------------------------"

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
        echo "TLS 指紋：$FP"

    elif [ "$TYPE" = "vless_reality" ]; then
        echo "SNI：$SNI"
        echo "TLS 指紋：$FP"
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

    echo "----------------------------------------"
}

# ------------------------------------------
# 啟用全局
# ------------------------------------------

enable_proxy() {

    if [ ! -f "$CONFIG_FILE" ]; then

        echo
        echo "還沒有配置節點。"
        echo "請先選擇協議並貼上鏈接。"
        echo

        pause
        return
    fi

    refresh_binary

    if [ -z "$SB_BIN" ]; then
        echo
        echo "尚未安裝 sing-box。"
        pause
        return
    fi

    echo
    echo "檢查配置..."

    if ! "$SB_BIN" check -c "$CONFIG_FILE"; then
        echo
        echo "配置檢查失敗，拒絕啟動。"
        pause
        return
    fi

    echo
    echo "正在啟動全局代理..."

    if service_restart; then
        echo
        echo "全局代理已開啟。"
    fi

    pause
}

# ------------------------------------------
# 關閉全局
# ------------------------------------------

disable_proxy() {

    service_stop

    echo
    echo "全局代理已關閉。"
    echo

    pause
}

# ------------------------------------------
# 狀態
# ------------------------------------------

show_status() {

    echo

    if [ "$INIT" = "systemd" ]; then

        systemctl status sing-box --no-pager 2>/dev/null || true

    elif [ "$INIT" = "openrc" ]; then

        rc-service sing-box status 2>/dev/null || true

    else

        if pgrep -x sing-box >/dev/null 2>&1; then
            echo "sing-box：運行中"
        else
            echo "sing-box：未運行"
        fi

    fi

    echo
    echo "TUN："

    if ip link show singtun0 >/dev/null 2>&1; then
        echo "singtun0：已建立"
    else
        echo "singtun0：未建立"
    fi

    pause
}

# ------------------------------------------
# 測試出口
# ------------------------------------------

test_ip() {

    echo
    echo "正在測試 IPv4 出口..."
    echo

    if command -v curl >/dev/null 2>&1; then
        curl -4 --connect-timeout 10 -fsSL https://api.ipify.org 2>/dev/null || true
        echo
    else
        echo "找不到 curl。"
    fi

    echo
    echo "正在測試 IPv6 出口..."
    echo

    if command -v curl >/dev/null 2>&1; then
        curl -6 --connect-timeout 10 -fsSL https://api64.ipify.org 2>/dev/null || true
        echo
    fi

    pause
}

# ------------------------------------------
# 安裝快捷命令
# ------------------------------------------

install_shortcut() {

    cat > /usr/local/bin/sbout <<'EOF'
#!/bin/bash

if [ -f /usr/local/sbin/sbout-main.sh ]; then
    exec bash /usr/local/sbin/sbout-main.sh "$@"
fi

echo "找不到 sbout 腳本。"
exit 1
EOF

    chmod +x /usr/local/bin/sbout

    mkdir -p /usr/local/sbin

    cp "$0" /usr/local/sbin/sbout-main.sh 2>/dev/null || true

    chmod +x /usr/local/sbin/sbout-main.sh 2>/dev/null || true
}

# ------------------------------------------
# 更新腳本
# ------------------------------------------

update_script() {

    if ! command -v curl >/dev/null 2>&1; then
        install_dependencies
    fi

    echo
    echo "正在更新 sbout..."

    local tmp="/tmp/sbout-update.sh"

    if curl -fsSL "$RAW_URL" -o "$tmp"; then

        chmod +x "$tmp"

        cp "$tmp" /usr/local/sbin/sbout-main.sh
        chmod +x /usr/local/sbin/sbout-main.sh

        echo
        echo "更新完成。"
        echo "重新執行 sbout 即可。"

    else

        echo
        echo "更新失敗。"
    fi

    echo
    pause
}

# ------------------------------------------
# 卸載
# ------------------------------------------

uninstall_all() {

    echo
    echo "這將刪除 sing-box 與目前配置。"
    echo

    read -r -p "確定卸載？輸入 YES： " confirm

    if [ "$confirm" != "YES" ]; then
        echo
        echo "已取消。"
        pause
        return
    fi

    service_stop

    if [ "$INIT" = "systemd" ]; then
        systemctl disable sing-box >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload

    elif [ "$INIT" = "openrc" ]; then
        rc-update del sing-box default >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box
    fi

    rm -rf "$CONFIG_DIR"

    rm -f /usr/local/bin/sbout
    rm -f /usr/local/sbin/sbout-main.sh

    if command -v apt-get >/dev/null 2>&1; then
        apt-get remove -y sing-box >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y sing-box >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y sing-box >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk del sing-box >/dev/null 2>&1 || true
    fi

    echo
    echo "卸載完成。"
    echo

    pause
}

# ------------------------------------------
# 主菜單
# ------------------------------------------

main_menu() {

    while true; do

        clear

        echo "========================================"
        echo "        sing-box 全局出口"
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
                pause
                ;;

            5)
                show_status
                ;;

            6)
                test_ip
                ;;

            7)
                install_singbox
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

# ------------------------------------------
# 初始化
# ------------------------------------------

check_root

detect_init

mkdir -p "$CONFIG_DIR"

install_shortcut

refresh_binary

# 第一次運行自動安裝
if [ -z "$SB_BIN" ]; then

    echo
    echo "首次運行，正在安裝 sing-box..."
    echo

    install_dependencies

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://sing-box.app/install.sh | sh
    fi

    refresh_binary
fi

if [ -z "$SB_BIN" ]; then

    echo
    echo "sing-box 安裝失敗。"
    echo
    echo "可以重新執行腳本再次安裝。"
    echo

    pause
    exit 1
fi

create_service

main_menu
