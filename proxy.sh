```bash
#!/bin/bash

# ============================================================
# sing-box 全局出口管理腳本
#
# 支持：
# 1. VLESS + WS + TLS
# 2. VLESS + Reality
# 3. SOCKS5
#
# 快捷命令：
# sbout
#
# 全局：
# TCP + UDP
# TUN 模式
# DNS 通過代理出口
# ============================================================

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="/etc/sing-box/config.json"
NODE_FILE="/etc/sing-box/node.conf"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

RAW_URL="https://raw.githubusercontent.com/edmond1294/-/main/proxy.sh"

# ============================================================
# 基礎函數
# ============================================================

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "請使用 root 運行此腳本。"
        exit 1
    fi
}

pause_screen() {
    echo
    read -r -p "按 Enter 返回..."
}

get_singbox() {
    if command -v sing-box >/dev/null 2>&1; then
        echo "sing-box"
        return
    fi

    if [ -x "/usr/local/bin/sing-box" ]; then
        echo "/usr/local/bin/sing-box"
        return
    fi

    echo ""
}

# ============================================================
# 系統判斷
# ============================================================

detect_system() {

    if [ -f /etc/debian_version ]; then
        OS="debian"

    elif [ -f /etc/redhat-release ]; then
        OS="redhat"

    elif [ -f /etc/alpine-release ]; then
        OS="alpine"

    elif [ -f /etc/arch-release ]; then
        OS="arch"

    else
        OS="unknown"
    fi
}

# ============================================================
# 安裝依賴
# ============================================================

install_dependencies() {

    detect_system

    echo
    echo "正在安裝依賴..."
    echo

    if [ "$OS" = "debian" ]; then

        apt-get update -y

        apt-get install -y \
            curl \
            wget \
            ca-certificates \
            python3 \
            iproute2 \
            unzip \
            tar

    elif [ "$OS" = "redhat" ]; then

        if command -v dnf >/dev/null 2>&1; then

            dnf install -y \
                curl \
                wget \
                ca-certificates \
                python3 \
                iproute \
                unzip \
                tar

        else

            yum install -y \
                curl \
                wget \
                ca-certificates \
                python3 \
                iproute \
                unzip \
                tar

        fi

    elif [ "$OS" = "alpine" ]; then

        apk add --no-cache \
            curl \
            wget \
            ca-certificates \
            python3 \
            iproute2 \
            unzip \
            tar

    elif [ "$OS" = "arch" ]; then

        pacman -Sy --noconfirm \
            curl \
            wget \
            ca-certificates \
            python \
            iproute2 \
            unzip \
            tar

    else

        echo "無法自動判斷系統。"
        echo "請先手動安裝 curl、python3、iproute。"

    fi
}

# ============================================================
# 安裝 sing-box
# ============================================================

install_singbox() {

    check_root

    install_dependencies

    echo
    echo "正在安裝 sing-box..."
    echo

    if command -v curl >/dev/null 2>&1; then

        if curl -fsSL https://sing-box.app/install.sh | sh; then
            echo
            echo "sing-box 安裝完成。"
        else
            echo
            echo "官方安裝腳本執行失敗。"
        fi

    else

        echo "curl 不存在，無法安裝。"
        return 1

    fi

    SB="$(get_singbox)"

    if [ -z "$SB" ]; then
        echo
        echo "找不到 sing-box。"
        echo "請重新執行安裝。"
        return 1
    fi

    echo
    "$SB" version 2>/dev/null || true
    echo

    create_service

    return 0
}

# ============================================================
# 建立 systemd 服務
# ============================================================

create_service() {

    SB="$(get_singbox)"

    if [ -z "$SB" ]; then
        return 1
    fi

    mkdir -p "$CONFIG_DIR"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box Global Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SB run -c $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1

    systemctl enable sing-box >/dev/null 2>&1

    echo "服務已建立。"
}

# ============================================================
# URL 解碼
# ============================================================

url_decode() {

    VALUE="$1"

    if command -v python3 >/dev/null 2>&1; then

        python3 - "$VALUE" <<'PY'
import sys
from urllib.parse import unquote

print(unquote(sys.argv[1]))
PY

    else

        printf '%b\n' "${VALUE//%/\\x}"

    fi
}

# ============================================================
# 解析 Server / Port
# ============================================================

parse_server_port() {

    HP="$1"

    # IPv6：[2001:db8::1]:443
    if echo "$HP" | grep -qE '^\[[0-9a-fA-F:]+\]:[0-9]+$'; then

        SERVER="$(echo "$HP" | sed -E 's/^\[([^]]+)\]:[0-9]+$/\1/')"

        PORT="$(echo "$HP" | sed -E 's/^.*:([0-9]+)$/\1/')"

    else

        SERVER="${HP%:*}"
        PORT="${HP##*:}"

    fi
}

# ============================================================
# VLESS WS + TLS
# ============================================================

parse_vless_ws() {

    LINK="$1"

    case "$LINK" in
        vless://*)
            ;;
        *)
            echo
            echo "錯誤：這不是 VLESS 鏈接。"
            return 1
            ;;
    esac

    BODY="${LINK#vless://}"

    BODY="${BODY%%#*}"

    MAIN="${BODY%%\?*}"

    if echo "$BODY" | grep -q '\?'; then
        QUERY="${BODY#*\?}"
    else
        QUERY=""
    fi

    UUID="${MAIN%@*}"
    HOSTPORT="${MAIN#*@}"

    if [ -z "$UUID" ] || [ -z "$HOSTPORT" ]; then
        echo "VLESS 鏈接格式錯誤。"
        return 1
    fi

    parse_server_port "$HOSTPORT"

    TYPE=""
    SECURITY=""
    SNI=""
    FP=""
    WS_HOST=""
    WS_PATH=""

    OLDIFS="$IFS"
    IFS='&'

    for PARAM in $QUERY; do

        KEY="${PARAM%%=*}"
        VALUE="${PARAM#*=}"

        VALUE="$(url_decode "$VALUE")"

        case "$KEY" in

            type)
                TYPE="$VALUE"
                ;;

            security)
                SECURITY="$VALUE"
                ;;

            sni)
                SNI="$VALUE"
                ;;

            fp)
                FP="$VALUE"
                ;;

            host)
                WS_HOST="$VALUE"
                ;;

            path)
                WS_PATH="$VALUE"
                ;;

        esac

    done

    IFS="$OLDIFS"

    if [ "$TYPE" != "ws" ]; then

        echo
        echo "錯誤：你選擇的是 VLESS + WS + TLS。"
        echo "但鏈接 type 不是 ws。"
        return 1

    fi

    if [ "$SECURITY" != "tls" ]; then

        echo
        echo "錯誤：你選擇的是 VLESS + WS + TLS。"
        echo "但鏈接 security 不是 tls。"
        return 1

    fi

    if [ -z "$SNI" ]; then
        SNI="$SERVER"
    fi

    if [ -z "$FP" ]; then
        FP="chrome"
    fi

    if [ -z "$WS_HOST" ]; then
        WS_HOST="$SNI"
    fi

    if [ -z "$WS_PATH" ]; then
        WS_PATH="/"
    fi

    NODE_TYPE="vless_ws"

    save_node

    generate_config

}

# ============================================================
# VLESS Reality
# ============================================================

parse_vless_reality() {

    LINK="$1"

    case "$LINK" in
        vless://*)
            ;;
        *)
            echo
            echo "錯誤：這不是 VLESS 鏈接。"
            return 1
            ;;
    esac

    BODY="${LINK#vless://}"

    BODY="${BODY%%#*}"

    MAIN="${BODY%%\?*}"

    if echo "$BODY" | grep -q '\?'; then
        QUERY="${BODY#*\?}"
    else
        QUERY=""
    fi

    UUID="${MAIN%@*}"
    HOSTPORT="${MAIN#*@}"

    if [ -z "$UUID" ] || [ -z "$HOSTPORT" ]; then
        echo "VLESS 鏈接格式錯誤。"
        return 1
    fi

    parse_server_port "$HOSTPORT"

    TYPE=""
    SECURITY=""
    SNI=""
    FP=""
    PBK=""
    SID=""
    FLOW=""

    OLDIFS="$IFS"
    IFS='&'

    for PARAM in $QUERY; do

        KEY="${PARAM%%=*}"
        VALUE="${PARAM#*=}"

        VALUE="$(url_decode "$VALUE")"

        case "$KEY" in

            type)
                TYPE="$VALUE"
                ;;

            security)
                SECURITY="$VALUE"
                ;;

            sni)
                SNI="$VALUE"
                ;;

            fp)
                FP="$VALUE"
                ;;

            pbk)
                PBK="$VALUE"
                ;;

            sid)
                SID="$VALUE"
                ;;

            flow)
                FLOW="$VALUE"
                ;;

        esac

    done

    IFS="$OLDIFS"

    if [ "$SECURITY" != "reality" ]; then

        echo
        echo "錯誤：你選擇的是 VLESS Reality。"
        echo "但鏈接 security 不是 reality。"
        return 1

    fi

    if [ -z "$PBK" ]; then

        echo
        echo "錯誤：Reality 鏈接缺少 pbk。"
        return 1

    fi

    if [ -z "$SNI" ]; then
        SNI="$SERVER"
    fi

    if [ -z "$FP" ]; then
        FP="chrome"
    fi

    NODE_TYPE="vless_reality"

    save_node

    generate_config

}

# ============================================================
# SOCKS5
# ============================================================

parse_socks5() {

    LINK="$1"

    case "$LINK" in

        socks://*)
            BODY="${LINK#socks://}"
            ;;

        socks5://*)
            BODY="${LINK#socks5://}"
            ;;

        *)
            echo
            echo "錯誤：這不是 SOCKS5 鏈接。"
            return 1
            ;;

    esac

    BODY="${BODY%%#*}"

    MAIN="${BODY%%\?*}"

    if echo "$BODY" | grep -q '\?'; then
        QUERY="${BODY#*\?}"
    else
        QUERY=""
    fi

    USER=""
    PASS=""

    if echo "$MAIN" | grep -q '@'; then

        AUTH="${MAIN%@*}"
        HOSTPORT="${MAIN#*@}"

        USER="${AUTH%%:*}"
        PASS="${AUTH#*:}"

        USER="$(url_decode "$USER")"
        PASS="$(url_decode "$PASS")"

    else

        HOSTPORT="$MAIN"

    fi

    parse_server_port "$HOSTPORT"

    if [ -z "$SERVER" ] || [ -z "$PORT" ]; then

        echo
        echo "SOCKS5 鏈接格式錯誤。"
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

    cat > "$NODE_FILE" <<EOF
NODE_TYPE=$NODE_TYPE
SERVER=$SERVER
PORT=$PORT
UUID=$UUID
SNI=$SNI
FP=$FP
WS_HOST=$WS_HOST
WS_PATH=$WS_PATH
PBK=$PBK
SID=$SID
FLOW=$FLOW
USER=$USER
PASS=$PASS
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

    unset NODE_TYPE
    unset SERVER
    unset PORT
    unset UUID
    unset SNI
    unset FP
    unset WS_HOST
    unset WS_PATH
    unset PBK
    unset SID
    unset FLOW
    unset USER
    unset PASS

    . "$NODE_FILE"

    return 0
}

# ============================================================
# 生成 VLESS WS
# ============================================================

generate_vless_ws_config() {

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
        "path": "$WS_PATH",
        "headers": {
          "Host": "$WS_HOST"
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

generate_vless_reality_config() {

    if [ -n "$FLOW" ]; then

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
      "flow": "$FLOW",
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
      "type": "vless",
      "tag": "proxy-out",
      "server": "$SERVER",
      "server_port": $PORT,
      "uuid": "$UUID",
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

    fi
}

# ============================================================
# 生成 SOCKS5
# ============================================================

generate_socks5_config() {

    if [ -n "$USER" ]; then

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

    case "$NODE_TYPE" in

        vless_ws)
            generate_vless_ws_config
            ;;

        vless_reality)
            generate_vless_reality_config
            ;;

        socks5)
            generate_socks5_config
            ;;

        *)
            echo "未知節點類型。"
            return 1
            ;;

    esac

    chmod 600 "$CONFIG_FILE"

    SB="$(get_singbox)"

    if [ -z "$SB" ]; then

        echo
        echo "找不到 sing-box。"
        return 1

    fi

    echo
    echo "正在檢查 sing-box 配置..."
    echo

    if "$SB" check -c "$CONFIG_FILE"; then

        echo
        echo "配置檢查通過。"
        return 0

    else

        echo
        echo "配置檢查失敗。"
        echo
        echo "配置文件：$CONFIG_FILE"
        return 1

    fi
}

# ============================================================
# 選擇協議
# ============================================================

choose_protocol() {

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

        read -r -p "請選擇: " CHOICE

        case "$CHOICE" in

            1)

                echo
                echo "請貼上 VLESS + WS + TLS 鏈接："
                echo

                read -r -p "> " LINK

                parse_vless_ws "$LINK"

                pause_screen

                ;;

            2)

                echo
                echo "請貼上 VLESS Reality 鏈接："
                echo

                read -r -p "> " LINK

                parse_vless_reality "$LINK"

                pause_screen

                ;;

            3)

                echo
                echo "請貼上 SOCKS5 鏈接："
                echo

                read -r -p "> " LINK

                parse_socks5 "$LINK"

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
    echo "             當前節點"
    echo "========================================"
    echo

    case "$NODE_TYPE" in

        vless_ws)
            echo "協議：VLESS + WS + TLS"
            ;;

        vless_reality)
            echo "協議：VLESS + Reality"
            ;;

        socks5)
            echo "協議：SOCKS5"
            ;;

    esac

    echo "服務器：$SERVER"
    echo "端口：$PORT"

    if [ "$NODE_TYPE" = "vless_ws" ]; then

        echo "SNI：$SNI"
        echo "Host：$WS_HOST"
        echo "Path：$WS_PATH"
        echo "指紋：$FP"

    elif [ "$NODE_TYPE" = "vless_reality" ]; then

        echo "SNI：$SNI"
        echo "指紋：$FP"
        echo "Short ID：$SID"

        if [ -n "$FLOW" ]; then
            echo "Flow：$FLOW"
        fi

    elif [ "$NODE_TYPE" = "socks5" ]; then

        if [ -n "$USER" ]; then
            echo "認證：已配置"
        else
            echo "認證：無"
        fi

    fi

    echo
}

# ============================================================
# 開啟代理
# ============================================================

enable_proxy() {

    if [ ! -f "$CONFIG_FILE" ]; then

        echo
        echo "尚未配置節點。"
        echo "請先選擇協議並貼上鏈接。"
        pause_screen
        return

    fi

    SB="$(get_singbox)"

    if [ -z "$SB" ]; then

        echo
        echo "尚未安裝 sing-box。"
        pause_screen
        return

    fi

    echo
    echo "正在檢查配置..."
    echo

    if ! "$SB" check -c "$CONFIG_FILE"; then

        echo
        echo "配置錯誤，沒有啟動代理。"
        pause_screen
        return

    fi

    systemctl daemon-reload >/dev/null 2>&1

    systemctl enable sing-box >/dev/null 2>&1

    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then

        echo
        echo "全局代理已開啟。"

    else

        echo
        echo "sing-box 啟動失敗。"
        echo
        echo "最近錯誤："
        echo

        journalctl -u sing-box --no-pager -n 30 2>/dev/null

    fi

    pause_screen
}

# ============================================================
# 關閉代理
# ============================================================

disable_proxy() {

    systemctl stop sing-box >/dev/null 2>&1

    echo
    echo "全局代理已關閉。"

    pause_screen
}

# ============================================================
# 查看狀態
# ============================================================

show_status() {

    echo
    echo "========================================"
    echo "             運行狀態"
    echo "========================================"
    echo

    if systemctl is-active --quiet sing-box; then
        echo "sing-box：運行中"
    else
        echo "sing-box：已停止"
    fi

    echo

    if ip link show singtun0 >/dev/null 2>&1; then
        echo "TUN：singtun0 已建立"
    else
        echo "TUN：未建立"
    fi

    echo

    pause_screen
}

# ============================================================
# 測試出口
# ============================================================

test_ip() {

    echo
    echo "正在測試 IPv4 出口..."
    echo

    curl -4 --connect-timeout 10 -fsSL https://api.ipify.org 2>/dev/null

    echo
    echo

    echo "正在測試 IPv6 出口..."
    echo

    curl -6 --connect-timeout 10 -fsSL https://api64.ipify.org 2>/dev/null

    echo
    echo

    pause_screen
}

# ============================================================
# 更新腳本
# ============================================================

update_script() {

    echo
    echo "正在下載最新版腳本..."
    echo

    TMP="/tmp/sbout-update.sh"

    if curl -fsSL "$RAW_URL" -o "$TMP"; then

        chmod +x "$TMP"

        mkdir -p /usr/local/sbin

        cp "$TMP" /usr/local/sbin/sbout-main.sh

        chmod +x /usr/local/sbin/sbout-main.sh

        echo
        echo "腳本更新完成。"

    else

        echo
        echo "腳本更新失敗。"

    fi

    pause_screen
}

# ============================================================
# 安裝快捷命令
# ============================================================

install_shortcut() {

    mkdir -p /usr/local/sbin

    cp "$0" /usr/local/sbin/sbout-main.sh 2>/dev/null || true

    chmod +x /usr/local/sbin/sbout-main.sh 2>/dev/null || true

    cat > /usr/local/bin/sbout <<'EOF'
#!/bin/bash

exec bash /usr/local/sbin/sbout-main.sh
EOF

    chmod +x /usr/local/bin/sbout
}

# ============================================================
# 卸載
# ============================================================

uninstall_all() {

    echo
    echo "即將卸載 sing-box 以及本腳本配置。"
    echo

    read -r -p "確定卸載？輸入 YES 繼續： " CONFIRM

    if [ "$CONFIRM" != "YES" ]; then

        echo
        echo "已取消。"
        pause_screen
        return

    fi

    systemctl stop sing-box >/dev/null 2>&1 || true

    systemctl disable sing-box >/dev/null 2>&1 || true

    rm -f "$SERVICE_FILE"

    systemctl daemon-reload >/dev/null 2>&1

    rm -rf "$CONFIG_DIR"

    rm -f /usr/local/bin/sbout
    rm -f /usr/local/sbin/sbout-main.sh

    echo
    echo "卸載完成。"

    exit 0
}

# ============================================================
# 主選單
# ============================================================

menu() {

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

        if systemctl is-active --quiet sing-box 2>/dev/null; then
            echo "狀態：運行中"
        else
            echo "狀態：已停止"
        fi

        echo
        echo "----------------------------------------"
        echo "1. 選擇協議並貼上鏈接"
        echo "2. 開啟全局代理"
        echo "3. 關閉全局代理"
        echo "4. 查看當前節點"
        echo "5. 查看運行狀態"
        echo "6. 測試出口 IP"
        echo "7. 重新安裝 sing-box"
        echo "8. 更新腳本"
        echo "9. 卸載 sing-box"
        echo "0. 退出"
        echo "----------------------------------------"
        echo

        read -r -p "請選擇: " CHOICE

        case "$CHOICE" in

            1)
                choose_protocol
                ;;

            2)
                enable_proxy
                ;;

            3)
                disable_proxy
                ;;

            4)
                clear
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
                install_singbox
                pause_screen
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
# 開始
# ============================================================

check_root

mkdir -p "$CONFIG_DIR"

install_shortcut

SB="$(get_singbox)"

if [ -z "$SB" ]; then

    echo
    echo "首次運行，正在安裝 sing-box..."
    echo

    install_singbox

    SB="$(get_singbox)"

    if [ -z "$SB" ]; then

        echo
        echo "sing-box 安裝失敗。"
        echo

        exit 1

    fi

fi

create_service

menu
```
