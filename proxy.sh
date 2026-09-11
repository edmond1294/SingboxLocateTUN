#!/bin/bash

set -e

SCRIPT_URL="https://raw.githubusercontent.com/edmond1294/SingboxLocateTUN/main/proxy.sh"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_NAME="sing-box"
SHORTCUT="/usr/local/bin/sbout"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 用户运行此脚本"
    exit 1
fi

log() {
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

err() {
    echo -e "${RED}$1${NC}"
}

install_singbox() {
    if command -v sing-box >/dev/null 2>&1; then
        return
    fi

    log "正在安装 sing-box..."

    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl ca-certificates jq python3 >/dev/null 2>&1

    curl -fsSL https://sing-box.app/install.sh | sh

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装失败"
        exit 1
    fi

    log "sing-box 安装完成"
}

prepare_dirs() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p /etc/systemd/system/sing-box.service.d
}

parse_uri() {
    local uri="$1"

    python3 - "$uri" > /tmp/sbout_node.json <<'PY'
import sys
import json
from urllib.parse import urlparse, parse_qs, unquote

uri = sys.argv[1].strip()

p = urlparse(uri)

scheme = p.scheme.lower()

if scheme == "socks5" or scheme == "socks5h":
    host = p.hostname
    port = p.port

    if not host or not port:
        raise SystemExit("SOCKS5 地址无效")

    node = {
        "type": "socks",
        "tag": "proxy-out",
        "server": host,
        "server_port": port
    }

    if p.username:
        node["username"] = unquote(p.username)

    if p.password:
        node["password"] = unquote(p.password)

    print(json.dumps(node, ensure_ascii=False))
    sys.exit(0)

if scheme != "vless":
    raise SystemExit("仅支持 VLESS 或 SOCKS5")

uuid = p.username

if not uuid:
    raise SystemExit("VLESS UUID 不存在")

host = p.hostname
port = p.port

if not host or not port:
    raise SystemExit("VLESS 地址或端口无效")

q = parse_qs(p.query)

def get(name, default=""):
    value = q.get(name, [default])[0]
    return unquote(value)

security = get("security", "")
network = get("type", get("network", "tcp"))

node = {
    "type": "vless",
    "tag": "proxy-out",
    "server": host,
    "server_port": port,
    "uuid": uuid
}

flow = get("flow")
if flow:
    node["flow"] = flow

if network:
    node["network"] = network

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

    node["tls"] = tls

elif security == "reality":
    tls = {
        "enabled": True,
        "reality": {
            "enabled": True
        }
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
        pbk = get("public_key")

    if pbk:
        tls["reality"]["public_key"] = pbk

    sid = get("sid")
    if not sid:
        sid = get("short_id")

    if sid:
        tls["reality"]["short_id"] = sid

    node["tls"] = tls

elif security in ("none", ""):
    pass

else:
    raise SystemExit("暂不支持此 VLESS security 类型: " + security)

if network == "ws":
    path = get("path", "/")

    transport = {
        "type": "ws",
        "path": path
    }

    host_header = get("host")

    if host_header:
        transport["headers"] = {
            "Host": host_header
        }

    node["transport"] = transport

elif network == "grpc":
    service_name = get("serviceName")

    transport = {
        "type": "grpc"
    }

    if service_name:
        transport["service_name"] = service_name

    node["transport"] = transport

print(json.dumps(node, ensure_ascii=False))
PY

    if [ $? -ne 0 ]; then
        rm -f /tmp/sbout_node.json
        return 1
    fi

    NODE_JSON="$(cat /tmp/sbout_node.json)"

    if [ -z "$NODE_JSON" ]; then
        return 1
    fi

    echo "$NODE_JSON"
}

generate_config() {
    local node="$1"

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "disabled": true
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
        "172.19.0.1/30"
      ],
      "mtu": 1500,
      "auto_route": true,
      "strict_route": true,
      "stack": "system"
    }
  ],

  "outbounds": [
    $node,

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

    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      }
    ],

    "final": "proxy-out"
  }
}
EOF
}

install_service_override() {
    mkdir -p /etc/systemd/system/sing-box.service.d

    cat > /etc/systemd/system/sing-box.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF

    systemctl daemon-reload
}

save_node() {
    local node="$1"

    mkdir -p "$CONFIG_DIR"

    echo "$node" > "${CONFIG_DIR}/node.json"

    chmod 600 "${CONFIG_DIR}/node.json"
}

load_node() {
    if [ ! -f "${CONFIG_DIR}/node.json" ]; then
        return 1
    fi

    cat "${CONFIG_DIR}/node.json"
}

configure_node() {
    echo
    echo "======================================"
    echo "        添加 / 更换代理节点"
    echo "======================================"
    echo
    echo "支持："
    echo "  VLESS + WS + TLS"
    echo "  VLESS + Reality"
    echo "  SOCKS5"
    echo
    echo "请直接粘贴完整节点 URI："
    echo

    read -r URI

    if [ -z "$URI" ]; then
        err "节点不能为空"
        return
    fi

    echo
    log "正在解析节点..."

    NODE="$(parse_uri "$URI")" || {
        err "节点解析失败"
        return
    }

    if ! echo "$NODE" | jq empty >/dev/null 2>&1; then
        err "节点格式错误"
        return
    fi

    save_node "$NODE"
    generate_config "$NODE"
    install_service_override

    if ! sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        err "sing-box 配置检查失败"

        echo
        sing-box check -c "$CONFIG_FILE" || true

        return
    fi

    systemctl restart "$SERVICE_NAME"

    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "节点配置成功"
        log "sing-box 已重新启动"
    else
        err "sing-box 启动失败"
        systemctl status "$SERVICE_NAME" --no-pager || true
    fi
}

enable_proxy() {
    if [ ! -f "${CONFIG_DIR}/node.json" ]; then
        warn "还没有添加节点"
        echo
        echo "请先选择：1. 添加 / 更换节点"
        return
    fi

    NODE="$(load_node)"

    generate_config "$NODE"
    install_service_override

    if ! sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        err "配置检查失败"
        sing-box check -c "$CONFIG_FILE"
        return
    fi

    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "全局代理已开启"
        echo
        echo "TCP：已通过 sing-box TUN"
        echo "UDP：已通过 sing-box TUN"
    else
        err "代理启动失败"
        systemctl status "$SERVICE_NAME" --no-pager || true
    fi
}

disable_proxy() {
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true

    log "全局代理已关闭"
}

show_status() {
    echo
    echo "======================================"
    echo "             当前状态"
    echo "======================================"
    echo

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "代理状态：${GREEN}运行中${NC}"
    else
        echo -e "代理状态：${RED}已停止${NC}"
    fi

    echo

    if [ -f "${CONFIG_DIR}/node.json" ]; then
        echo "当前节点类型："

        TYPE="$(jq -r '.type // "unknown"' "${CONFIG_DIR}/node.json")"

        case "$TYPE" in
            vless)
                echo "VLESS"
                ;;
            socks)
                echo "SOCKS5"
                ;;
            *)
                echo "$TYPE"
                ;;
        esac
    else
        echo "当前节点：未配置"
    fi

    echo

    systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || true
}

test_proxy() {
    echo
    echo "======================================"
    echo "             测试出口"
    echo "======================================"
    echo

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        err "代理当前没有运行"
        return
    fi

    echo "IPv4 出口："

    if command -v curl >/dev/null 2>&1; then
        curl -4 --max-time 15 https://api.ipify.org 2>/dev/null || echo "IPv4 测试失败"
    else
        echo "系统没有 curl"
    fi

    echo
    echo

    echo "IPv6 出口："

    if command -v curl >/dev/null 2>&1; then
        curl -6 --max-time 15 https://api6.ipify.org 2>/dev/null || echo "IPv6 测试失败"
    else
        echo "系统没有 curl"
    fi

    echo
}

uninstall_all() {
    echo
    read -r -p "确定卸载 sing-box 全局代理？[y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true

    rm -f "$SHORTCUT"
    rm -f /usr/local/bin/out

    rm -rf "$CONFIG_DIR"
    rm -rf /etc/systemd/system/sing-box.service.d

    systemctl daemon-reload

    if command -v sing-box >/dev/null 2>&1; then
        rm -f "$(command -v sing-box)"
    fi

    log "卸载完成"
}

install_shortcut() {
    cat > "$SHORTCUT" <<EOF
#!/bin/bash
exec bash <(curl -fsSL "$SCRIPT_URL")
EOF

    chmod +x "$SHORTCUT"

    rm -f /usr/local/bin/out
}

install_all() {
    echo
    log "开始安装 sing-box 全局代理..."

    install_singbox
    prepare_dirs
    install_service_override
    install_shortcut

    echo
    log "安装完成"
    echo
    echo "以后直接输入："
    echo
    echo "  sbout"
    echo
    echo "即可打开管理菜单。"
    echo
}

main_menu() {
    while true; do
        clear

        echo "======================================"
        echo "          sing-box 全局出口"
        echo "======================================"
        echo
        echo "1. 添加 / 更换节点"
        echo "2. 开启代理"
        echo "3. 关闭代理"
        echo "4. 查看状态"
        echo "5. 测试出口"
        echo "6. 卸载"
        echo "0. 退出"
        echo
        read -r -p "请选择 [0-6]: " choice

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
                show_status
                ;;
            5)
                test_proxy
                ;;
            6)
                uninstall_all
                exit 0
                ;;
            0)
                exit 0
                ;;
            *)
                err "无效选择"
                ;;
        esac

        echo
        read -r -p "按 Enter 返回菜单..."
    done
}

case "${1:-}" in
    install)
        install_all
        ;;
    on)
        install_singbox
        prepare_dirs
        enable_proxy
        ;;
    off)
        disable_proxy
        ;;
    status)
        show_status
        ;;
    test)
        test_proxy
        ;;
    uninstall)
        uninstall_all
        ;;
    *)
        install_singbox
        prepare_dirs
        install_shortcut
        main_menu
        ;;
esac
