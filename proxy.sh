#!/bin/bash

# ============================================================
# VPS 全局出口代理
# sing-box
# 支持：
# 1. VLESS + WS + TLS（Argo）
# 2. SOCKS5
# 3. VLESS + Reality
#
# 使用：
# bash proxy.sh
# 或
# out
# ============================================================

set -u

CONFIG="/etc/sing-box/config.json"
BACKUP="/etc/sing-box/config.json.bak"
STATE_DIR="/etc/vps-out"
STATE_FILE="$STATE_DIR/type"
SCRIPT_PATH="/usr/local/bin/vps-out"
OUT_CMD="/usr/local/bin/out"

mkdir -p "$STATE_DIR"

# ------------------------------------------------------------
# 基礎
# ------------------------------------------------------------

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行此脚本"
    exit 1
fi

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

pause_screen() {
    echo
    read -r -p "按回车返回菜单..." _
}

# ------------------------------------------------------------
# 安装基础组件
# ------------------------------------------------------------

install_basic() {

    if command_exists apt-get; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y >/dev/null 2>&1

        apt-get install -y \
            curl \
            ca-certificates \
            python3 \
            iproute2 \
            >/dev/null 2>&1

    elif command_exists dnf; then

        dnf install -y \
            curl \
            ca-certificates \
            python3 \
            iproute \
            >/dev/null 2>&1

    elif command_exists yum; then

        yum install -y \
            curl \
            ca-certificates \
            python3 \
            iproute \
            >/dev/null 2>&1

    elif command_exists apk; then

        apk add \
            curl \
            ca-certificates \
            python3 \
            iproute2 \
            >/dev/null 2>&1

    else
        echo "无法识别当前系统的包管理器"
        exit 1
    fi
}

# ------------------------------------------------------------
# 安装 sing-box
# ------------------------------------------------------------

install_singbox() {

    if command_exists sing-box; then
        return
    fi

    echo
    echo "正在安装 sing-box..."
    echo

    curl -fsSL https://sing-box.app/install.sh | sh

    if ! command_exists sing-box; then
        echo
        echo "sing-box 安装失败"
        exit 1
    fi

    echo
    echo "sing-box 安装完成"
}

# ------------------------------------------------------------
# Python URL 解析器
# ------------------------------------------------------------

parse_node() {

    NODE_URL="$1"
    NODE_TYPE="$2"

    python3 - "$NODE_URL" "$NODE_TYPE" <<'PY'
import sys
from urllib.parse import urlsplit, parse_qs, unquote

url = sys.argv[1]
mode = sys.argv[2]

u = urlsplit(url)
q = parse_qs(u.query)

def get(name, default=""):
    return unquote(q.get(name, [default])[0])

host = u.hostname or ""
port = u.port or 0
username = unquote(u.username or "")
password = unquote(u.password or "")
uuid = unquote(u.username or "")
fragment = unquote(u.fragment or "")

if mode == "vless_ws_tls":

    security = get("security")
    transport = get("type")

    if u.scheme.lower() != "vless":
        print("ERROR|VLESS链接格式错误")
        sys.exit(1)

    if not host or not port or not uuid:
        print("ERROR|VLESS链接缺少服务器、端口或UUID")
        sys.exit(1)

    if security != "tls":
        print("ERROR|此链接不是TLS")
        sys.exit(1)

    if transport != "ws":
        print("ERROR|此链接不是WS")
        sys.exit(1)

    sni = get("sni")
    fp = get("fp")
    ws_host = get("host")
    path = get("path")

    if not sni:
        sni = host

    if not path:
        path = "/"

    if not ws_host:
        ws_host = sni

    alpn = get("alpn")

    print("OK")
    print("SERVER=" + host)
    print("PORT=" + str(port))
    print("UUID=" + uuid)
    print("SNI=" + sni)
    print("FP=" + fp)
    print("WS_HOST=" + ws_host)
    print("WS_PATH=" + path)
    print("ALPN=" + alpn)
    print("NAME=" + fragment)

elif mode == "socks5":

    if u.scheme.lower() not in ["socks5", "socks", "socks5h"]:
        print("ERROR|SOCKS5链接格式错误")
        sys.exit(1)

    if not host or not port:
        print("ERROR|SOCKS5链接缺少服务器或端口")
        sys.exit(1)

    print("OK")
    print("SERVER=" + host)
    print("PORT=" + str(port))
    print("USERNAME=" + username)
    print("PASSWORD=" + password)
    print("NAME=" + fragment)

elif mode == "vless_reality":

    security = get("security")

    if u.scheme.lower() != "vless":
        print("ERROR|VLESS链接格式错误")
        sys.exit(1)

    if not host or not port or not uuid:
        print("ERROR|VLESS链接缺少服务器、端口或UUID")
        sys.exit(1)

    if security != "reality":
        print("ERROR|此链接不是Reality")
        sys.exit(1)

    sni = get("sni")
    fp = get("fp")
    pbk = get("pbk")
    sid = get("sid")
    flow = get("flow")

    if not sni:
        print("ERROR|Reality缺少sni")
        sys.exit(1)

    if not pbk:
        print("ERROR|Reality缺少pbk")
        sys.exit(1)

    print("OK")
    print("SERVER=" + host)
    print("PORT=" + str(port))
    print("UUID=" + uuid)
    print("SNI=" + sni)
    print("FP=" + fp)
    print("PBK=" + pbk)
    print("SID=" + sid)
    print("FLOW=" + flow)
    print("NAME=" + fragment)

else:

    print("ERROR|未知协议")
    sys.exit(1)

PY
}

# ------------------------------------------------------------
# 生成 VLESS WS TLS
# ------------------------------------------------------------

create_vless_ws_tls() {

    NODE="$1"

    RESULT="$(parse_node "$NODE" "vless_ws_tls")"

    if echo "$RESULT" | grep -q '^ERROR|'; then
        echo "$RESULT" | sed 's/^ERROR|//'
        return 1
    fi

    eval "$(
        echo "$RESULT" |
        grep -E '^(SERVER|PORT|UUID|SNI|FP|WS_HOST|WS_PATH|ALPN)='
    )"

    if [ -f "$CONFIG" ]; then
        cp -f "$CONFIG" "$BACKUP"
    fi

    ALPN_JSON=""

    if [ -n "${ALPN:-}" ]; then
        ALPN_JSON=$(python3 - "$ALPN" <<'PY'
import sys, json
x=sys.argv[1]
print(json.dumps([i.strip() for i in x.split(",") if i.strip()], ensure_ascii=False))
PY
)
    fi

    if [ -n "$ALPN_JSON" ]; then

        cat > "$CONFIG" <<EOF
{
  "\$schema": "https://sing-box.sagernet.org/schema.json",

  "log": {
    "level": "info"
  },

  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns",
        "server": "1.1.1.1",
        "server_port": 53
      }
    ],
    "final": "dns",
    "strategy": "prefer_ipv4"
  },

  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sb-tun",
      "address": [
        "172.18.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "route_exclude_address": [
        "192.168.0.0/16",
        "172.16.0.0/12",
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "fc00::/7",
        "fe80::/10",
        "::1/128"
      ]
    }
  ],

  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$SERVER",
      "server_port": $PORT,
      "uuid": "$UUID",

      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "${FP:-chrome}"
        },
        "alpn": $ALPN_JSON
      },

      "transport": {
        "type": "ws",
        "path": "$WS_PATH",
        "headers": {
          "Host": "$WS_HOST"
        }
      }
    }
  ],

  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

    else

        cat > "$CONFIG" <<EOF
{
  "\$schema": "https://sing-box.sagernet.org/schema.json",

  "log": {
    "level": "info"
  },

  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns",
        "server": "1.1.1.1",
        "server_port": 53
      }
    ],
    "final": "dns",
    "strategy": "prefer_ipv4"
  },

  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sb-tun",
      "address": [
        "172.18.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "route_exclude_address": [
        "192.168.0.0/16",
        "172.16.0.0/12",
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "fc00::/7",
        "fe80::/10",
        "::1/128"
      ]
    }
  ],

  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$SERVER",
      "server_port": $PORT,
      "uuid": "$UUID",

      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "${FP:-chrome}"
        }
      },

      "transport": {
        "type": "ws",
        "path": "$WS_PATH",
        "headers": {
          "Host": "$WS_HOST"
        }
      }
    }
  ],

  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

    fi

    echo "vless_ws_tls" > "$STATE_FILE"

    return 0
}

# ------------------------------------------------------------
# 生成 SOCKS5
# ------------------------------------------------------------

create_socks5() {

    NODE="$1"

    RESULT="$(parse_node "$NODE" "socks5")"

    if echo "$RESULT" | grep -q '^ERROR|'; then
        echo "$RESULT" | sed 's/^ERROR|//'
        return 1
    fi

    eval "$(
        echo "$RESULT" |
        grep -E '^(SERVER|PORT|USERNAME|PASSWORD)='
    )"

    if [ -f "$CONFIG" ]; then
        cp -f "$CONFIG" "$BACKUP"
    fi

    if [ -n "${USERNAME:-}" ]; then

        cat > "$CONFIG" <<EOF
{
  "\$schema": "https://sing-box.sagernet.org/schema.json",

  "log": {
    "level": "info"
  },

  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns",
        "server": "1.1.1.1",
        "server_port": 53
      }
    ],
    "final": "dns",
    "strategy": "prefer_ipv4"
  },

  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sb-tun",
      "address": [
        "172.18.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "route_exclude_address": [
        "192.168.0.0/16",
        "172.16.0.0/12",
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "fc00::/7",
        "fe80::/10",
        "::1/128"
      ]
    }
  ],

  "outbounds": [
    {
      "type": "socks",
      "tag": "proxy",
      "server": "$SERVER",
      "server_port": $PORT,
      "version": "5",
      "username": "$USERNAME",
      "password": "$PASSWORD"
    }
  ],

  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

    else

        cat > "$CONFIG" <<EOF
{
  "\$schema": "https://sing-box.sagernet.org/schema.json",

  "log": {
    "level": "info"
  },

  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns",
        "server": "1.1.1.1",
        "server_port": 53
      }
    ],
    "final": "dns",
    "strategy": "prefer_ipv4"
  },

  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sb-tun",
      "address": [
        "172.18.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "route_exclude_address": [
        "192.168.0.0/16",
        "172.16.0.0/12",
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "fc00::/7",
        "fe80::/10",
        "::1/128"
      ]
    }
  ],

  "outbounds": [
    {
      "type": "socks",
      "tag": "proxy",
      "server": "$SERVER",
      "server_port": $PORT,
      "version": "5"
    }
  ],

  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

    fi

    echo "socks5" > "$STATE_FILE"

    return 0
}

# ------------------------------------------------------------
# 生成 VLESS Reality
# ------------------------------------------------------------

create_vless_reality() {

    NODE="$1"

    RESULT="$(parse_node "$NODE" "vless_reality")"

    if echo "$RESULT" | grep -q '^ERROR|'; then
        echo "$RESULT" | sed 's/^ERROR|//'
        return 1
    fi

    eval "$(
        echo "$RESULT" |
        grep -E '^(SERVER|PORT|UUID|SNI|FP|PBK|SID|FLOW)='
    )"

    if [ -f "$CONFIG" ]; then
        cp -f "$CONFIG" "$BACKUP"
    fi

    FLOW_JSON=""

    if [ -n "${FLOW:-}" ]; then
        FLOW_JSON=",\n      \"flow\": \"$FLOW\""
    fi

    cat > "$CONFIG" <<EOF
{
  "\$schema": "https://sing-box.sagernet.org/schema.json",

  "log": {
    "level": "info"
  },

  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns",
        "server": "1.1.1.1",
        "server_port": 53
      }
    ],
    "final": "dns",
    "strategy": "prefer_ipv4"
  },

  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sb-tun",
      "address": [
        "172.18.0.1/30",
        "fdfe:dcba:9876::1/126"
      ],
      "auto_route": true,
      "strict_route": true,
      "stack": "system",
      "route_exclude_address": [
        "192.168.0.0/16",
        "172.16.0.0/12",
        "10.0.0.0/8",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "fc00::/7",
        "fe80::/10",
        "::1/128"
      ]
    }
  ],

  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "$SERVER",
      "server_port": $PORT,
      "uuid": "$UUID"$FLOW_JSON,

      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "${FP:-chrome}"
        },
        "reality": {
          "enabled": true,
          "public_key": "$PBK",
          "short_id": "$SID"
        }
      }
    }
  ],

  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
EOF

    echo "vless_reality" > "$STATE_FILE"

    return 0
}

# ------------------------------------------------------------
# 檢查配置
# ------------------------------------------------------------

check_config() {

    echo
    echo "正在检查 sing-box 配置..."
    echo

    if sing-box check -c "$CONFIG"; then
        echo
        echo "配置检查通过"
        return 0
    else
        echo
        echo "配置检查失败"
        echo
        return 1
    fi
}

# ------------------------------------------------------------
# 啟動
# ------------------------------------------------------------

start_proxy() {

    systemctl daemon-reload >/dev/null 2>&1

    systemctl enable sing-box >/dev/null 2>&1

    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then
        echo
        echo "全局代理已启动"
        return 0
    fi

    echo
    echo "sing-box 启动失败"
    echo
    systemctl status sing-box --no-pager -l
    return 1
}

# ------------------------------------------------------------
# 停止
# ------------------------------------------------------------

stop_proxy() {

    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1

    rm -f "$STATE_FILE"

    echo
    echo "全局代理已关闭"
}

# ------------------------------------------------------------
# 顯示狀態
# ------------------------------------------------------------

show_status() {

    echo
    echo "========================================"
    echo " VPS 全局出口代理"
    echo "========================================"

    if systemctl is-active --quiet sing-box; then
        echo "状态：已启用"
    else
        echo "状态：未启用"
    fi

    if [ -f "$STATE_FILE" ]; then

        TYPE="$(cat "$STATE_FILE")"

        case "$TYPE" in

            vless_ws_tls)
                echo "协议：VLESS + WS + TLS"
                ;;

            socks5)
                echo "协议：SOCKS5"
                ;;

            vless_reality)
                echo "协议：VLESS + Reality"
                ;;

            *)
                echo "协议：未知"
                ;;

        esac

    else
        echo "协议：未配置"
    fi

    echo

    if command_exists sing-box; then
        echo "sing-box：$(sing-box version 2>/dev/null | head -n 1)"
    else
        echo "sing-box：未安装"
    fi

    echo

    if [ -f "$CONFIG" ]; then
        echo "配置文件：正常"
    else
        echo "配置文件：不存在"
    fi

    echo "========================================"
}

# ------------------------------------------------------------
# 配置 VLESS WS TLS
# ------------------------------------------------------------

menu_vless_ws_tls() {

    echo
    echo "========================================"
    echo " 配置 VLESS + WS + TLS（Argo）"
    echo "========================================"
    echo
    echo "请粘贴完整 VLESS 链接："
    echo

    read -r NODE

    if [ -z "$NODE" ]; then
        echo "没有输入节点"
        pause_screen
        return
    fi

    if create_vless_ws_tls "$NODE"; then

        echo
        echo "节点解析成功"
        echo

        if check_config; then
            start_proxy
        fi

    fi

    pause_screen
}

# ------------------------------------------------------------
# 配置 SOCKS5
# ------------------------------------------------------------

menu_socks5() {

    echo
    echo "========================================"
    echo " 配置 SOCKS5"
    echo "========================================"
    echo
    echo "支持："
    echo "socks5://user:password@server:port"
    echo "socks5://server:port"
    echo
    echo "请粘贴完整 SOCKS5 链接："
    echo

    read -r NODE

    if [ -z "$NODE" ]; then
        echo "没有输入节点"
        pause_screen
        return
    fi

    if create_socks5 "$NODE"; then

        echo
        echo "节点解析成功"
        echo

        if check_config; then
            start_proxy
        fi

    fi

    pause_screen
}

# ------------------------------------------------------------
# 配置 VLESS Reality
# ------------------------------------------------------------

menu_vless_reality() {

    echo
    echo "========================================"
    echo " 配置 VLESS + Reality"
    echo "========================================"
    echo
    echo "请粘贴完整 VLESS Reality 链接："
    echo

    read -r NODE

    if [ -z "$NODE" ]; then
        echo "没有输入节点"
        pause_screen
        return
    fi

    if create_vless_reality "$NODE"; then

        echo
        echo "节点解析成功"
        echo

        if check_config; then
            start_proxy
        fi

    fi

    pause_screen
}

# ------------------------------------------------------------
# 安裝
# ------------------------------------------------------------

install_all() {

    install_basic
    install_singbox

    mkdir -p /etc/sing-box
}

# ------------------------------------------------------------
# 主菜单
# ------------------------------------------------------------

main_menu() {

    while true; do

        clear

        echo "========================================"
        echo "        VPS 全局出口代理"
        echo "========================================"
        echo

        if systemctl is-active --quiet sing-box; then
            echo "当前状态：已启用"
        else
            echo "当前状态：已关闭"
        fi

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

                clear

                echo "========================================"
                echo "            选择协议"
                echo "========================================"
                echo
                echo "1. VLESS + WS + TLS（Argo）"
                echo "2. SOCKS5"
                echo "3. VLESS + Reality"
                echo "0. 返回"
                echo
                echo -n "请选择："

                read -r PROTOCOL

                case "$PROTOCOL" in

                    1)
                        menu_vless_ws_tls
                        ;;

                    2)
                        menu_socks5
                        ;;

                    3)
                        menu_vless_reality
                        ;;

                    0)
                        ;;

                    *)
                        echo
                        echo "无效选择"
                        sleep 1
                        ;;

                esac

                ;;

            2)

                stop_proxy
                pause_screen
                ;;

            3)

                show_status
                pause_screen
                ;;

            0)

                exit 0
                ;;

            *)

                echo
                echo "无效选择"
                sleep 1
                ;;

        esac

    done
}

# ------------------------------------------------------------
# 快捷命令
# ------------------------------------------------------------

install_command() {

    cp -f "$0" "$SCRIPT_PATH" 2>/dev/null || true

    chmod +x "$SCRIPT_PATH" 2>/dev/null || true

    ln -sf "$SCRIPT_PATH" "$OUT_CMD"

    chmod +x "$OUT_CMD" 2>/dev/null || true
}

# ------------------------------------------------------------
# 主程序
# ------------------------------------------------------------

install_all

install_command

main_menu
