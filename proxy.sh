#!/bin/bash

# ============================================================
# sing-box 全局出口管理脚本
# 支持：
# Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux
# Fedora / Alpine / Arch / Amazon Linux
# amd64 / arm64 / armv7 / 386
# ============================================================

set +e

SCRIPT_URL="https://raw.githubusercontent.com/edmond1294/-/main/proxy.sh"

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
NODE_FILE="${CONFIG_DIR}/node.json"

SERVICE_NAME="sing-box"
SHORTCUT="/usr/local/bin/sbout"

TUN_NAME="singtun0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SYSTEM=""
ARCH=""
PKG=""

# ============================================================
# 基础函数
# ============================================================

msg() {
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

error() {
    echo -e "${RED}$1${NC}"
}

info() {
    echo -e "${BLUE}$1${NC}"
}

pause() {
    echo
    read -r -p "按 Enter 返回菜单..."
}

root_check() {
    if [ "$(id -u)" != "0" ]; then
        error "请使用 root 用户运行"
        exit 1
    fi
}

# ============================================================
# 系统检测
# ============================================================

detect_system() {

    SYSTEM="unknown"

    if [ -f /etc/os-release ]; then
        . /etc/os-release

        case "$ID" in
            ubuntu)
                SYSTEM="ubuntu"
                ;;
            debian)
                SYSTEM="debian"
                ;;
            centos)
                SYSTEM="centos"
                ;;
            rhel)
                SYSTEM="rhel"
                ;;
            rocky)
                SYSTEM="rocky"
                ;;
            almalinux)
                SYSTEM="almalinux"
                ;;
            fedora)
                SYSTEM="fedora"
                ;;
            alpine)
                SYSTEM="alpine"
                ;;
            arch)
                SYSTEM="arch"
                ;;
            amzn)
                SYSTEM="amazon"
                ;;
            *)
                case "$ID_LIKE" in
                    *debian*)
                        SYSTEM="debian"
                        ;;
                    *rhel*|*fedora*)
                        SYSTEM="rhel"
                        ;;
                    *arch*)
                        SYSTEM="arch"
                        ;;
                    *)
                        SYSTEM="$ID"
                        ;;
                esac
                ;;
        esac
    fi

    ARCH_RAW="$(uname -m)"

    case "$ARCH_RAW" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l|armv7*)
            ARCH="armv7"
            ;;
        i386|i686)
            ARCH="386"
            ;;
        *)
            ARCH="$ARCH_RAW"
            ;;
    esac
}

# ============================================================
# 包管理器
# ============================================================

detect_package_manager() {

    PKG=""

    if command -v apt-get >/dev/null 2>&1; then
        PKG="apt"
        return
    fi

    if command -v dnf >/dev/null 2>&1; then
        PKG="dnf"
        return
    fi

    if command -v yum >/dev/null 2>&1; then
        PKG="yum"
        return
    fi

    if command -v apk >/dev/null 2>&1; then
        PKG="apk"
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        PKG="pacman"
        return
    fi
}

# ============================================================
# 安装基础依赖
# ============================================================

install_dependencies() {

    detect_package_manager

    case "$PKG" in

        apt)
            export DEBIAN_FRONTEND=noninteractive

            apt-get update -y >/dev/null 2>&1

            apt-get install -y \
                curl \
                wget \
                ca-certificates \
                jq \
                python3 \
                iproute2 \
                procps \
                >/dev/null 2>&1
            ;;

        dnf)
            dnf install -y \
                curl \
                wget \
                ca-certificates \
                jq \
                python3 \
                iproute \
                procps \
                >/dev/null 2>&1
            ;;

        yum)
            yum install -y \
                curl \
                wget \
                ca-certificates \
                jq \
                python3 \
                iproute \
                procps \
                >/dev/null 2>&1
            ;;

        apk)
            apk add \
                curl \
                wget \
                ca-certificates \
                jq \
                python3 \
                iproute2 \
                procps \
                >/dev/null 2>&1
            ;;

        pacman)
            pacman -Sy --noconfirm \
                curl \
                wget \
                ca-certificates \
                jq \
                python \
                iproute2 \
                procps \
                >/dev/null 2>&1
            ;;

        *)
            warn "无法自动识别包管理器"
            ;;
    esac
}

# ============================================================
# 安装 sing-box
# ============================================================

install_singbox() {

    echo
    info "正在检查 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then

        VERSION="$(sing-box version 2>/dev/null | head -n 1)"

        msg "sing-box 已安装"
        echo "$VERSION"

        return 0
    fi

    echo
    info "正在安装 sing-box..."
    echo

    install_dependencies

    if command -v sing-box >/dev/null 2>&1; then
        msg "sing-box 已安装"
        return 0
    fi

    # ========================================================
    # 官方安装脚本
    # ========================================================

    if command -v curl >/dev/null 2>&1; then

        echo "尝试使用官方安装方式..."

        curl -fsSL https://sing-box.app/install.sh -o /tmp/sing-box-install.sh

        if [ -s /tmp/sing-box-install.sh ]; then

            bash /tmp/sing-box-install.sh

            rm -f /tmp/sing-box-install.sh
        fi
    fi

    if command -v sing-box >/dev/null 2>&1; then
        msg "sing-box 安装成功"
        return 0
    fi

    # ========================================================
    # 官方安装失败 → GitHub Release
    # ========================================================

    warn "官方安装方式失败，尝试 GitHub Release..."

    if ! command -v curl >/dev/null 2>&1; then
        error "系统没有 curl"
        return 1
    fi

    API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

    DOWNLOAD_URL="$(
        curl -fsSL "$API" 2>/dev/null |
        python3 - "$ARCH" <<'PY'
import sys
import json

arch = sys.argv[1]

try:
    data = json.load(sys.stdin)
except:
    sys.exit(1)

assets = data.get("assets", [])

for a in assets:
    name = a.get("name", "")
    url = a.get("browser_download_url", "")

    if not name.endswith(".tar.gz"):
        continue

    if "linux" not in name:
        continue

    if arch == "amd64" and "linux-amd64" in name:
        print(url)
        break

    if arch == "arm64" and "linux-arm64" in name:
        print(url)
        break

    if arch == "armv7" and "linux-armv7" in name:
        print(url)
        break

    if arch == "386" and "linux-386" in name:
        print(url)
        break
PY
)"

    if [ -z "$DOWNLOAD_URL" ]; then
        error "无法找到适合当前系统架构的 sing-box"
        echo
        echo "系统：$SYSTEM"
        echo "架构：$ARCH"
        echo
        return 1
    fi

    mkdir -p /tmp/sing-box-install

    curl -fL "$DOWNLOAD_URL" \
        -o /tmp/sing-box.tar.gz

    if [ ! -s /tmp/sing-box.tar.gz ]; then
        error "sing-box 下载失败"
        return 1
    fi

    tar -xzf /tmp/sing-box.tar.gz \
        -C /tmp/sing-box-install

    SB_BIN="$(find /tmp/sing-box-install -type f -name sing-box | head -n 1)"

    if [ -z "$SB_BIN" ]; then
        error "没有找到 sing-box 二进制文件"
        return 1
    fi

    install -m 755 "$SB_BIN" /usr/local/bin/sing-box

    rm -rf /tmp/sing-box-install
    rm -f /tmp/sing-box.tar.gz

    if command -v sing-box >/dev/null 2>&1; then
        msg "sing-box 安装成功"
        return 0
    fi

    error "sing-box 安装失败"
    return 1
}

# ============================================================
# 创建目录
# ============================================================

prepare_dirs() {

    mkdir -p "$CONFIG_DIR"

    mkdir -p /etc/systemd/system/sing-box.service.d
}

# ============================================================
# 创建 systemd 服务
# ============================================================

create_service() {

    if ! command -v systemctl >/dev/null 2>&1; then
        warn "当前系统没有 systemd"
        return 0
    fi

    cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/sing-box.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=3
LimitNOFILE=1048576
EOF

    systemctl daemon-reload
}

# ============================================================
# URI 解析
# ============================================================

parse_uri() {

    URI="$1"

    python3 - "$URI" > /tmp/sbout_node.json <<'PY'
import sys
import json
from urllib.parse import urlparse, parse_qs, unquote

uri = sys.argv[1].strip()

p = urlparse(uri)

scheme = p.scheme.lower()

# ============================================================
# SOCKS5
# ============================================================

if scheme in ("socks5", "socks5h"):

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

# ============================================================
# VLESS
# ============================================================

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
    return unquote(q.get(name, [default])[0])

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

# ============================================================
# TLS
# ============================================================

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

# ============================================================
# Reality
# ============================================================

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

    raise SystemExit(
        "不支持的 security 类型: " + security
    )

# ============================================================
# WebSocket
# ============================================================

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

# ============================================================
# gRPC
# ============================================================

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

    RESULT=$?

    if [ "$RESULT" != "0" ]; then
        rm -f /tmp/sbout_node.json
        return 1
    fi

    if [ ! -s /tmp/sbout_node.json ]; then
        return 1
    fi

    cat /tmp/sbout_node.json
}

# ============================================================
# 生成配置
# ============================================================

generate_config() {

    NODE="$1"

    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "disabled": false,
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
      "interface_name": "$TUN_NAME",
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
    $NODE,

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

# ============================================================
# 保存节点
# ============================================================

save_node() {

    echo "$1" > "$NODE_FILE"

    chmod 600 "$NODE_FILE"
}

load_node() {

    if [ ! -f "$NODE_FILE" ]; then
        return 1
    fi

    cat "$NODE_FILE"
}

# ============================================================
# 添加 / 更换节点
# ============================================================

configure_node() {

    clear

    echo "========================================"
    echo "        添加 / 更换代理节点"
    echo "========================================"
    echo
    echo "支持："
    echo "  VLESS + WS + TLS"
    echo "  VLESS + Reality"
    echo "  SOCKS5"
    echo
    echo "直接粘贴完整节点 URI："
    echo

    read -r URI

    if [ -z "$URI" ]; then
        error "节点不能为空"
        pause
        return
    fi

    echo
    info "正在解析节点..."

    NODE="$(parse_uri "$URI")"

    if [ -z "$NODE" ]; then
        error "节点解析失败"
        pause
        return
    fi

    echo "$NODE" | jq empty >/dev/null 2>&1

    if [ "$?" != "0" ]; then
        error "节点格式错误"
        pause
        return
    fi

    save_node "$NODE"

    generate_config "$NODE"

    if ! sing-box check -c "$CONFIG_FILE"; then

        error "sing-box 配置检查失败"

        rm -f "$CONFIG_FILE"

        pause
        return
    fi

    create_service

    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then

        msg "节点配置成功"
        msg "sing-box 已启动"

    else

        error "sing-box 启动失败"

        echo
        systemctl status sing-box --no-pager -l

    fi

    pause
}

# ============================================================
# 开启代理
# ============================================================

enable_proxy() {

    if [ ! -f "$NODE_FILE" ]; then

        warn "还没有配置节点"

        echo
        echo "请先选择：1. 添加 / 更换节点"

        pause
        return
    fi

    NODE="$(load_node)"

    generate_config "$NODE"

    if ! sing-box check -c "$CONFIG_FILE"; then

        error "配置检查失败"

        pause
        return
    fi

    create_service

    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box

    sleep 2

    if systemctl is-active --quiet sing-box; then

        msg "全局代理已开启"

        echo
        echo "TCP：通过 sing-box TUN"
        echo "UDP：通过 sing-box TUN"

    else

        error "代理启动失败"

        echo
        systemctl status sing-box --no-pager -l

    fi

    pause
}

# ============================================================
# 关闭代理
# ============================================================

disable_proxy() {

    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1

    msg "全局代理已关闭"

    pause
}

# ============================================================
# 查看状态
# ============================================================

show_status() {

    clear

    echo "========================================"
    echo "              当前状态"
    echo "========================================"
    echo

    echo "系统：$SYSTEM"
    echo "架构：$ARCH"
    echo

    if command -v sing-box >/dev/null 2>&1; then

        echo "sing-box：已安装"

        sing-box version 2>/dev/null | head -n 1

    else

        echo "sing-box：未安装"

    fi

    echo

    if [ -f "$NODE_FILE" ]; then

        TYPE="$(jq -r '.type // "unknown"' "$NODE_FILE" 2>/dev/null)"

        echo "节点类型：$TYPE"

    else

        echo "节点：未配置"

    fi

    echo

    if systemctl is-active --quiet sing-box; then

        echo -e "代理状态：${GREEN}运行中${NC}"

    else

        echo -e "代理状态：${RED}已停止${NC}"

    fi

    echo

    systemctl status sing-box \
        --no-pager \
        -l \
        2>/dev/null || true

    pause
}

# ============================================================
# 测试出口
# ============================================================

test_proxy() {

    clear

    echo "========================================"
    echo "              测试出口"
    echo "========================================"
    echo

    if ! systemctl is-active --quiet sing-box; then

        error "sing-box 当前没有运行"

        pause
        return
    fi

    if ! command -v curl >/dev/null 2>&1; then
        install_dependencies
    fi

    echo "IPv4："

    curl -4 \
        --connect-timeout 10 \
        --max-time 20 \
        https://api.ipify.org \
        2>/dev/null

    echo
    echo

    echo "IPv6："

    curl -6 \
        --connect-timeout 10 \
        --max-time 20 \
        https://api6.ipify.org \
        2>/dev/null || echo "IPv6 不可用或出口不支持 IPv6"

    echo
    echo

    echo "DNS："

    curl \
        --connect-timeout 10 \
        --max-time 20 \
        https://www.cloudflare.com/cdn-cgi/trace \
        2>/dev/null | grep -E 'ip=|loc=' || true

    pause
}

# ============================================================
# 创建 sbout
# ============================================================

create_shortcut() {

    cat > "$SHORTCUT" <<EOF
#!/bin/bash

SCRIPT_URL="$SCRIPT_URL"

exec bash <(curl -fsSL "\$SCRIPT_URL")
EOF

    chmod +x "$SHORTCUT"

    # 删除旧 out
    rm -f /usr/local/bin/out
}

# ============================================================
# 卸载
# ============================================================

uninstall_all() {

    clear

    echo "========================================"
    echo "              卸载代理"
    echo "========================================"
    echo

    read -r -p "确定卸载 sing-box？[y/N]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        return
    fi

    systemctl stop sing-box >/dev/null 2>&1 || true
    systemctl disable sing-box >/dev/null 2>&1 || true

    rm -f "$SHORTCUT"
    rm -f /usr/local/bin/out

    rm -rf "$CONFIG_DIR"

    rm -f /etc/systemd/system/sing-box.service
    rm -rf /etc/systemd/system/sing-box.service.d

    systemctl daemon-reload

    rm -f /usr/local/bin/sing-box

    msg "卸载完成"

    exit 0
}

# ============================================================
# 安装
# ============================================================

initial_install() {

    clear

    echo "========================================"
    echo "       sing-box 全局出口安装"
    echo "========================================"
    echo

    detect_system
    detect_package_manager

    echo "系统：$SYSTEM"
    echo "架构：$ARCH"
    echo "包管理器：$PKG"
    echo

    if [ "$ARCH" = "unknown" ]; then
        error "无法识别 CPU 架构"
        pause
        return
    fi

    install_singbox

    if ! command -v sing-box >/dev/null 2>&1; then

        error "sing-box 安装失败"

        echo
        echo "不会退出脚本。"
        echo "请检查上面的错误信息。"

        pause
        return
    fi

    prepare_dirs
    create_service
    create_shortcut

    echo
    msg "安装完成"
    echo
    echo "快捷命令："
    echo
    echo "  sbout"
    echo

    pause
}

# ============================================================
# 主菜单
# ============================================================

main_menu() {

    while true; do

        clear

        detect_system
        detect_package_manager

        echo "========================================"
        echo "          sing-box 全局出口"
        echo "========================================"
        echo

        echo "系统：$SYSTEM"
        echo "架构：$ARCH"

        if command -v sing-box >/dev/null 2>&1; then
            echo "sing-box：已安装"
        else
            echo "sing-box：未安装"
        fi

        echo

        echo "1. 添加 / 更换节点"
        echo "2. 开启代理"
        echo "3. 关闭代理"
        echo "4. 查看状态"
        echo "5. 测试出口"
        echo "6. 卸载"
        echo "0. 退出"

        echo

        read -r -p "请选择 [0-6]: " CHOICE

        case "$CHOICE" in

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
                ;;

            0)
                exit 0
                ;;

            *)
                error "无效选择"
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# 主程序
# ============================================================

root_check

detect_system
detect_package_manager

# 第一次执行：
# 没有 sing-box → 安装 → 不退出 → 直接进入菜单

if ! command -v sing-box >/dev/null 2>&1; then

    initial_install

fi

# 再次确认
if ! command -v sing-box >/dev/null 2>&1; then

    error "当前仍未检测到 sing-box"

    echo
    echo "请重新运行脚本进行安装。"

    pause

fi

prepare_dirs
create_shortcut

main_menu
