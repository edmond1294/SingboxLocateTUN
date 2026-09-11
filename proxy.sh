#!/usr/bin/env bash

set -u

CONFIG="/etc/sing-box/config.json"
BACKUP_DIR="/etc/sing-box/backup"
SERVICE="sing-box"
BIN="/usr/local/bin/sing-box"
CMD="/usr/local/bin/out"
VPS_CMD="/usr/local/bin/vps-out"

TMP="/tmp/out_proxy_$$"

mkdir -p "$BACKUP_DIR"

cleanup() {
    rm -f \
        "$TMP" \
        "$TMP.link" \
        "$TMP.json" \
        "$TMP.py" \
        "$TMP.err" \
        2>/dev/null || true
}

trap cleanup EXIT

# ============================================================
# ROOT
# ============================================================

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行。"
    exit 1
fi

# ============================================================
# 系统检测
# ============================================================

detect_os() {

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="${ID:-unknown}"
        VERSION_ID="${VERSION_ID:-}"
    else
        OS="unknown"
    fi
}

# ============================================================
# 安装依赖
# ============================================================

install_dependencies() {

    echo
    echo "正在检测系统..."

    detect_os

    case "$OS" in

        ubuntu|debian)

            export DEBIAN_FRONTEND=noninteractive

            apt-get update -y

            apt-get install -y \
                curl \
                wget \
                ca-certificates \
                python3 \
                iproute2 \
                procps \
                tar \
                gzip \
                unzip

            ;;

        centos|rhel|rocky|almalinux|fedora)

            if command -v dnf >/dev/null 2>&1; then

                dnf install -y \
                    curl \
                    wget \
                    ca-certificates \
                    python3 \
                    iproute \
                    procps \
                    tar \
                    gzip \
                    unzip

            else

                yum install -y \
                    curl \
                    wget \
                    ca-certificates \
                    python3 \
                    iproute \
                    procps \
                    tar \
                    gzip \
                    unzip

            fi

            ;;

        *)

            echo "未识别系统：$OS"

            if command -v apt-get >/dev/null 2>&1; then

                export DEBIAN_FRONTEND=noninteractive

                apt-get update -y

                apt-get install -y \
                    curl \
                    wget \
                    ca-certificates \
                    python3 \
                    iproute2 \
                    procps \
                    tar \
                    gzip \
                    unzip

            else

                echo "无法自动安装依赖。"
                exit 1

            fi

            ;;

    esac
}

# ============================================================
# 安装 sing-box
# ============================================================

install_singbox() {

    echo
    echo "正在检查 sing-box..."

    SB_BIN=""

    if command -v sing-box >/dev/null 2>&1; then
        SB_BIN="$(command -v sing-box)"
    elif [ -x "$BIN" ]; then
        SB_BIN="$BIN"
    fi

    if [ -n "$SB_BIN" ]; then

        echo "检测到 sing-box："

        "$SB_BIN" version 2>/dev/null | head -n 1

        return 0
    fi

    echo
    echo "未安装 sing-box。"
    echo "开始自动安装..."

    bash <(curl -fsSL https://sing-box.app/install.sh)

    if command -v sing-box >/dev/null 2>&1; then
        SB_BIN="$(command -v sing-box)"
    elif [ -x "$BIN" ]; then
        SB_BIN="$BIN"
    fi

    if [ -z "${SB_BIN:-}" ]; then

        echo
        echo "sing-box 安装失败。"
        exit 1

    fi

    echo
    echo "sing-box 安装完成："

    "$SB_BIN" version 2>/dev/null | head -n 1
}

# ============================================================
# systemd
# ============================================================

install_service() {

    mkdir -p /etc/systemd/system

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Proxy Service
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SB_BIN run -c $CONFIG
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# ============================================================
# Python 解析器
# ============================================================

parse_link() {

    LINK="$1"

    printf '%s' "$LINK" > "$TMP.link"

    cat > "$TMP.py" <<'PY'
import sys
import json
import urllib.parse
import base64

link = open(sys.argv[1], "r", encoding="utf-8").read().strip()

def uq(v):
    return urllib.parse.unquote(v or "")

def decode_b64(v):

    v = v.strip()

    v += "=" * ((4 - len(v) % 4) % 4)

    try:
        return base64.urlsafe_b64decode(v).decode()
    except:
        return ""

def parse_vless(url):

    p = urllib.parse.urlsplit(url)

    if p.scheme.lower() != "vless":
        raise ValueError("不是 VLESS 链接")

    if not p.username:
        raise ValueError("VLESS 缺少 UUID")

    if not p.hostname:
        raise ValueError("VLESS 缺少服务器地址")

    if not p.port:
        raise ValueError("VLESS 缺少服务器端口")

    uuid = uq(p.username)

    server = p.hostname

    port = p.port

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    def get(name, default=""):
        return q.get(name, [default])[0]

    security = get("security").lower()

    transport = get("type").lower()

    sni = get("sni")

    fp = get("fp") or "chrome"

    flow = get("flow")

    # ========================================================
    # Reality
    # ========================================================

    if security == "reality":

        public_key = get("pbk")

        short_id = get("sid")

        if not public_key:
            raise ValueError(
                "Reality 链接缺少 pbk 公钥"
            )

        out = {

            "type": "vless",

            "tag": "proxy",

            "server": server,

            "server_port": port,

            "uuid": uuid,

            "tls": {

                "enabled": True,

                "server_name": sni or server,

                "utls": {

                    "enabled": True,

                    "fingerprint": fp

                },

                "reality": {

                    "enabled": True,

                    "public_key": public_key,

                    "short_id": short_id

                }

            }

        }

        if flow:
            out["flow"] = flow

        return out, "VLESS + Reality"

    # ========================================================
    # WS + TLS
    # ========================================================

    if transport == "ws" and security == "tls":

        path = uq(
            get("path", "/")
        )

        ws_host = get("host")

        out = {

            "type": "vless",

            "tag": "proxy",

            "server": server,

            "server_port": port,

            "uuid": uuid,

            "tls": {

                "enabled": True,

                "server_name":
                    sni or ws_host or server,

                "utls": {

                    "enabled": True,

                    "fingerprint": fp

                }

            },

            "transport": {

                "type": "ws",

                "path": path or "/",

                "headers": {}

            }

        }

        if ws_host:

            out["transport"]["headers"]["Host"] = ws_host

        if flow:

            out["flow"] = flow

        return out, "VLESS + WS + TLS"

    raise ValueError(
        "不支持的 VLESS 类型。"
        "请选择 VLESS + WS + TLS 或 VLESS + Reality"
    )

# ============================================================
# SOCKS5
# ============================================================

def parse_socks(url):

    p = urllib.parse.urlsplit(url)

    if p.scheme.lower() not in (
        "socks",
        "socks5",
        "socks5h"
    ):
        raise ValueError("不是 SOCKS5 链接")

    if not p.hostname:
        raise ValueError("SOCKS5 缺少服务器地址")

    if not p.port:
        raise ValueError("SOCKS5 缺少端口")

    out = {

        "type": "socks",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "version": "5"

    }

    if p.username:

        out["username"] = urllib.parse.unquote(
            p.username
        )

    if p.password:

        out["password"] = urllib.parse.unquote(
            p.password
        )

    return out, "SOCKS5"

# ============================================================
# 主解析
# ============================================================

def parse(url):

    url = url.strip()

    if url.startswith("vless://"):

        return parse_vless(url)

    if (
        url.startswith("socks://")
        or url.startswith("socks5://")
        or url.startswith("socks5h://")
    ):

        return parse_socks(url)

    decoded = decode_b64(url)

    if decoded:

        for line in decoded.splitlines():

            line = line.strip()

            if line.startswith("vless://"):

                return parse_vless(line)

            if (
                line.startswith("socks://")
                or line.startswith("socks5://")
                or line.startswith("socks5h://")
            ):

                return parse_socks(line)

    raise ValueError(
        "无法识别链接。"
        "请粘贴 vless:// 或 socks5:// 链接"
    )

obj, name = parse(link)

print(
    json.dumps(
        {
            "name": name,
            "outbound": obj
        },
        ensure_ascii=False
    )
)
PY

    if ! python3 "$TMP.py" "$TMP.link" \
        > "$TMP.json" \
        2> "$TMP.err"
    then

        echo
        echo "解析失败："
        cat "$TMP.err"

        return 1
    fi

    return 0
}

# ============================================================
# 生成配置
# ============================================================

generate_config() {

    PARSED="$1"

    mkdir -p /etc/sing-box
    mkdir -p "$BACKUP_DIR"

    # --------------------------------------------------------
    # 备份旧配置
    # --------------------------------------------------------

    if [ -f "$CONFIG" ]; then

        cp -f "$CONFIG" \
            "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"

    fi

    python3 - "$PARSED" "$CONFIG" <<'PY'

import sys
import json
import os

parsed_file = sys.argv[1]

config_file = sys.argv[2]

with open(
    parsed_file,
    "r",
    encoding="utf-8"
) as f:

    data = json.load(f)

outbound = data["outbound"]

# ============================================================
# 强制 proxy tag
# ============================================================

outbound["tag"] = "proxy"

# ============================================================
# 关键：
# sing-box 1.12+ 必须明确指定 domain resolver
# ============================================================

outbound["domain_resolver"] = "dns-bootstrap"

# ============================================================
# 完整配置
# ============================================================

config = {

    "log": {

        "disabled": False,

        "level": "warn"

    },

    # ========================================================
    # DNS
    # ========================================================

    "dns": {

        "servers": [

            {
                "type": "udp",

                "tag": "dns-bootstrap",

                "server": "1.1.1.1",

                "server_port": 53
            },

            {
                "type": "udp",

                "tag": "dns-proxy",

                "server": "1.1.1.1",

                "server_port": 53,

                "detour": "proxy"
            }

        ],

        "final": "dns-proxy"

    },

    # ========================================================
    # TUN
    # ========================================================

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

            "auto_route": True,

            "strict_route": True

        }

    ],

    # ========================================================
    # Outbound
    # ========================================================

    "outbounds": [

        outbound,

        {

            "type": "direct",

            "tag": "direct"

        },

        {

            "type": "block",

            "tag": "block"

        }

    ],

    # ========================================================
    # Route
    # ========================================================

    "route": {

        "auto_detect_interface": True,

        # sing-box 1.12+
        "default_domain_resolver": "dns-bootstrap",

        "rules": [

            {

                "protocol": "dns",

                "action": "hijack-dns"

            }

        ],

        "final": "proxy"

    }

}

# ============================================================
# 写配置
# ============================================================

tmp_file = config_file + ".tmp"

with open(
    tmp_file,
    "w",
    encoding="utf-8"
) as f:

    json.dump(
        config,
        f,
        ensure_ascii=False,
        indent=2
    )

    f.write("\n")

os.replace(
    tmp_file,
    config_file
)

PY
}

# ============================================================
# 启动
# ============================================================

start_proxy() {

    echo
    echo "正在检查配置..."
    echo

    # 防止旧进程占用 TUN
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true

    sleep 1

    if ! "$SB_BIN" check -c "$CONFIG"; then

        echo
        echo "配置检查失败。"
        echo

        return 1
    fi

    install_service

    systemctl daemon-reload

    systemctl enable "$SERVICE" \
        >/dev/null 2>&1

    systemctl reset-failed "$SERVICE" \
        >/dev/null 2>&1

    systemctl restart "$SERVICE"

    sleep 3

    if systemctl is-active --quiet "$SERVICE"; then

        echo
        echo "全局出口已开启。"
        echo

        return 0
    fi

    echo
    echo "sing-box 启动失败。"
    echo

    journalctl \
        -u "$SERVICE" \
        -n 40 \
        --no-pager

    return 1
}

# ============================================================
# 停止
# ============================================================

stop_proxy() {

    systemctl stop "$SERVICE" \
        >/dev/null 2>&1 || true

    echo
    echo "全局出口已关闭。"
    echo
}

# ============================================================
# 状态
# ============================================================

status_proxy() {

    echo

    if systemctl is-active --quiet "$SERVICE"; then

        echo "状态：运行中"

    else

        echo "状态：已停止"

    fi

    echo

    if [ -f "$CONFIG" ]; then

        echo "当前配置："
        echo "$CONFIG"

    fi

    echo
}

# ============================================================
# 测试
# ============================================================

test_proxy() {

    echo
    echo "正在测试当前出口..."
    echo

    echo "IPv4："

    curl -4 \
        --connect-timeout 5 \
        --max-time 15 \
        -s \
        https://api.ipify.org

    echo

    echo
    echo "IPv6："

    curl -6 \
        --connect-timeout 5 \
        --max-time 15 \
        -s \
        https://api64.ipify.org \
        2>/dev/null || true

    echo
}

# ============================================================
# 选择出口
# ============================================================

select_proxy() {

    clear

    echo "=========================================="
    echo "           VPS 全局出口管理"
    echo "=========================================="
    echo
    echo "请选择出口类型："
    echo
    echo "# 1. VLESS + WS + TLS"
    echo "# 2. VLESS + Reality"
    echo "# 3. SOCKS5"
    echo

    read -r -p "请选择 [1-3]：" TYPE

    case "$TYPE" in

        1)
            EXPECTED="VLESS + WS + TLS"
            ;;

        2)
            EXPECTED="VLESS + Reality"
            ;;

        3)
            EXPECTED="SOCKS5"
            ;;

        *)
            echo
            echo "无效选择。"
            sleep 1
            return
            ;;

    esac

    echo
    echo "你选择：$EXPECTED"
    echo
    echo "请直接粘贴完整连接："
    echo

    read -r -p "> " LINK

    if [ -z "$LINK" ]; then

        echo
        echo "连接不能为空。"
        sleep 1

        return
    fi

    echo
    echo "正在解析..."
    echo

    if ! parse_link "$LINK"; then

        sleep 2

        return
    fi

    PARSED_NAME="$(
        python3 - "$TMP.json" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    "r",
    encoding="utf-8"
) as f:

    print(
        json.load(f)["name"]
    )
PY
)"

    if [ "$PARSED_NAME" != "$EXPECTED" ]; then

        echo
        echo "链接类型与选择不一致。"
        echo
        echo "选择：$EXPECTED"
        echo "解析：$PARSED_NAME"
        echo

        read -r \
            -p "是否仍然使用此出口？[y/N]：" \
            ANSWER

        case "$ANSWER" in

            y|Y)
                ;;

            *)
                echo "已取消。"
                sleep 1
                return
                ;;

        esac
    fi

    generate_config "$TMP.json"

    echo
    echo "配置已生成。"
    echo

    if ! start_proxy; then

        echo
        echo "启动失败，请查看上方日志。"
        echo

        read -r \
            -p "按 Enter 返回菜单..." _

        return
    fi

    echo
    echo "出口类型：$PARSED_NAME"
    echo
    echo "配置完成。"
    echo

    read -r \
        -p "按 Enter 返回菜单..." _
}

# ============================================================
# 快速安装
# ============================================================

quick_install() {

    install_dependencies

    install_singbox

    echo
    echo "依赖与 sing-box 已准备完成。"
    echo

    read -r \
        -p "按 Enter 返回菜单..." _
}

# ============================================================
# 查看配置
# ============================================================

show_config() {

    clear

    echo "=========================================="
    echo "              当前配置"
    echo "=========================================="
    echo

    if [ -f "$CONFIG" ]; then

        cat "$CONFIG"

    else

        echo "暂无配置。"

    fi

    echo

    read -r \
        -p "按 Enter 返回菜单..." _
}

# ============================================================
# 日志
# ============================================================

show_log() {

    clear

    echo "=========================================="
    echo "              sing-box 日志"
    echo "=========================================="
    echo

    journalctl \
        -u "$SERVICE" \
        -n 80 \
        --no-pager

    echo

    read -r \
        -p "按 Enter 返回菜单..." _
}

# ============================================================
# 卸载
# ============================================================

uninstall_proxy() {

    echo
    echo "警告：这会删除 sing-box 全局出口配置。"
    echo

    read -r \
        -p "确认卸载？[y/N]：" \
        ANSWER

    case "$ANSWER" in

        y|Y)

            systemctl disable \
                --now "$SERVICE" \
                >/dev/null 2>&1 || true

            rm -f "$CONFIG"

            rm -f \
                /etc/systemd/system/sing-box.service

            systemctl daemon-reload

            echo
            echo "全局出口配置已删除。"
            echo "sing-box 程序本身未删除。"
            echo

            ;;

        *)

            echo "已取消。"

            ;;

    esac

    sleep 1
}

# ============================================================
# 安装 out 命令
# ============================================================

install_out_command() {

    cat > "$CMD" <<'EOF'
#!/usr/bin/env bash

exec /usr/local/bin/vps-out
EOF

    chmod +x "$CMD"

    # ========================================================
    # vps-out
    # ========================================================

    cat > "$VPS_CMD" <<'EOF'
#!/usr/bin/env bash

CONFIG="/etc/sing-box/config.json"

SERVICE="sing-box"

SB_BIN="$(
    command -v sing-box 2>/dev/null ||
    echo /usr/local/bin/sing-box
)"

TMP="/tmp/vps-out-$$"

cleanup() {

    rm -f "$TMP"* \
        2>/dev/null || true

}

trap cleanup EXIT

# ============================================================
# 解析链接
# ============================================================

parse_link() {

    LINK="$1"

    printf '%s' "$LINK" \
        > "$TMP.link"

    cat > "$TMP.py" <<'PY'

import sys
import json
import urllib.parse
import base64

link = open(
    sys.argv[1],
    "r",
    encoding="utf-8"
).read().strip()

def uq(v):

    return urllib.parse.unquote(
        v or ""
    )

def decode_b64(v):

    v = v.strip()

    v += "=" * (
        (4 - len(v) % 4) % 4
    )

    try:

        return base64.urlsafe_b64decode(
            v
        ).decode()

    except:

        return ""

def parse_vless(url):

    p = urllib.parse.urlsplit(url)

    if not p.username:
        raise ValueError(
            "VLESS 缺少 UUID"
        )

    if not p.hostname:
        raise ValueError(
            "VLESS 缺少服务器"
        )

    if not p.port:
        raise ValueError(
            "VLESS 缺少端口"
        )

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    def g(k, d=""):

        return q.get(k, [d])[0]

    uuid = uq(p.username)

    server = p.hostname

    port = p.port

    security = g("security").lower()

    typ = g("type").lower()

    sni = g("sni")

    fp = g("fp") or "chrome"

    flow = g("flow")

    if security == "reality":

        pbk = g("pbk")

        sid = g("sid")

        if not pbk:

            raise ValueError(
                "Reality 缺少 pbk"
            )

        out = {

            "type": "vless",

            "tag": "proxy",

            "server": server,

            "server_port": port,

            "uuid": uuid,

            "domain_resolver":
                "dns-bootstrap",

            "tls": {

                "enabled": True,

                "server_name":
                    sni or server,

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

        }

        if flow:

            out["flow"] = flow

        return out

    if typ == "ws" and security == "tls":

        path = uq(
            g("path", "/")
        )

        host = g("host")

        out = {

            "type": "vless",

            "tag": "proxy",

            "server": server,

            "server_port": port,

            "uuid": uuid,

            "domain_resolver":
                "dns-bootstrap",

            "tls": {

                "enabled": True,

                "server_name":
                    sni or host or server,

                "utls": {

                    "enabled": True,

                    "fingerprint": fp

                }

            },

            "transport": {

                "type": "ws",

                "path": path,

                "headers": {}

            }

        }

        if host:

            out["transport"]["headers"]["Host"] = host

        if flow:

            out["flow"] = flow

        return out

    raise ValueError(
        "不支持的 VLESS 类型"
    )

def parse_socks(url):

    p = urllib.parse.urlsplit(url)

    if not p.hostname:

        raise ValueError(
            "SOCKS5 缺少服务器"
        )

    if not p.port:

        raise ValueError(
            "SOCKS5 缺少端口"
        )

    out = {

        "type": "socks",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "version": "5",

        "domain_resolver":
            "dns-bootstrap"

    }

    if p.username:

        out["username"] = \
            urllib.parse.unquote(
                p.username
            )

    if p.password:

        out["password"] = \
            urllib.parse.unquote(
                p.password
            )

    return out

if link.startswith("vless://"):

    obj = parse_vless(link)

elif (
    link.startswith("socks://")
    or
    link.startswith("socks5://")
    or
    link.startswith("socks5h://")
):

    obj = parse_socks(link)

else:

    decoded = decode_b64(link)

    if decoded.startswith("vless://"):

        obj = parse_vless(
            decoded.strip()
        )

    elif (
        decoded.startswith("socks://")
        or
        decoded.startswith("socks5://")
        or
        decoded.startswith("socks5h://")
    ):

        obj = parse_socks(
            decoded.strip()
        )

    else:

        raise ValueError(
            "无法识别链接"
        )

print(
    json.dumps(
        obj,
        ensure_ascii=False,
        indent=2
    )
)

PY

    python3 "$TMP.py" "$TMP.link" \
        > "$TMP.out" \
        2> "$TMP.err"
}

# ============================================================
# 写入配置
# ============================================================

write_config() {

    PARSED="$1"

    mkdir -p /etc/sing-box

    if [ -f "$CONFIG" ]; then

        cp "$CONFIG" \
            "/etc/sing-box/config.backup.json"

    fi

    python3 - "$PARSED" "$CONFIG" <<'PY'

import sys
import json
import os

src = sys.argv[1]

dst = sys.argv[2]

with open(
    src,
    encoding="utf-8"
) as f:

    outbound = json.load(f)

# ============================================================
# 强制唯一 proxy
# ============================================================

outbound["tag"] = "proxy"

outbound["domain_resolver"] = \
    "dns-bootstrap"

# ============================================================
# 新配置
# ============================================================

config = {

    "log": {

        "disabled": False,

        "level": "warn"

    },

    "dns": {

        "servers": [

            {

                "type": "udp",

                "tag": "dns-bootstrap",

                "server": "1.1.1.1",

                "server_port": 53

            },

            {

                "type": "udp",

                "tag": "dns-proxy",

                "server": "1.1.1.1",

                "server_port": 53,

                "detour": "proxy"

            }

        ],

        "final": "dns-proxy"

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

            "auto_route": True,

            "strict_route": True

        }

    ],

    "outbounds": [

        outbound,

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

        "auto_detect_interface": True,

        "default_domain_resolver":
            "dns-bootstrap",

        "rules": [

            {

                "protocol": "dns",

                "action": "hijack-dns"

            }

        ],

        "final": "proxy"

    }

}

tmp = dst + ".tmp"

with open(
    tmp,
    "w",
    encoding="utf-8"
) as f:

    json.dump(
        config,
        f,
        ensure_ascii=False,
        indent=2
    )

    f.write("\n")

os.replace(
    tmp,
    dst
)

PY
}

# ============================================================
# 启动
# ============================================================

start() {

    if [ ! -f "$CONFIG" ]; then

        echo
        echo "暂无出口配置。"

        return 1

    fi

    if ! "$SB_BIN" check \
        -c "$CONFIG"
    then

        echo
        echo "配置检查失败。"

        return 1

    fi

    systemctl daemon-reload

    systemctl enable "$SERVICE" \
        >/dev/null 2>&1

    systemctl reset-failed "$SERVICE" \
        >/dev/null 2>&1

    systemctl restart "$SERVICE"

    sleep 3

    if systemctl is-active \
        --quiet "$SERVICE"
    then

        echo
        echo "全局出口已开启。"
        echo

        return 0

    fi

    echo
    echo "启动失败。"
    echo

    journalctl \
        -u "$SERVICE" \
        -n 30 \
        --no-pager

    return 1
}

# ============================================================
# 菜单
# ============================================================

menu() {

    while true; do

        clear

        echo "=========================================="
        echo "              VPS 出口管理"
        echo "=========================================="
        echo

        echo "当前状态："

        if systemctl is-active \
            --quiet "$SERVICE"
        then

            echo "运行中"

        else

            echo "已停止"

        fi

        echo
        echo "# 1. 更换出口"
        echo "# 2. 开启全局出口"
        echo "# 3. 关闭全局出口"
        echo "# 4. 查看状态"
        echo "# 5. 测试出口"
        echo "# 6. 查看配置"
        echo "# 7. 查看日志"
        echo "# 8. 退出"
        echo

        read -r \
            -p "请选择 [1-8]：" \
            CHOICE

        case "$CHOICE" in

            1)

                echo
                echo "=========================================="
                echo "             选择出口类型"
                echo "=========================================="
                echo
                echo "# 1. VLESS + WS + TLS"
                echo "# 2. VLESS + Reality"
                echo "# 3. SOCKS5"
                echo

                read -r \
                    -p "请选择 [1-3]：" \
                    TYPE

                case "$TYPE" in

                    1)
                        EXPECT="VLESS + WS + TLS"
                        ;;

                    2)
                        EXPECT="VLESS + Reality"
                        ;;

                    3)
                        EXPECT="SOCKS5"
                        ;;

                    *)

                        echo "无效选择。"

                        sleep 1

                        continue

                        ;;

                esac

                echo
                echo "请选择：$EXPECT"
                echo
                echo "直接粘贴完整链接："
                echo

                read -r \
                    -p "> " \
                    LINK

                if [ -z "$LINK" ]; then

                    echo "不能为空。"

                    sleep 1

                    continue

                fi

                if ! parse_link "$LINK"; then

                    echo
                    echo "解析失败："

                    cat "$TMP.err" \
                        2>/dev/null || true

                    sleep 2

                    continue

                fi

                write_config "$TMP.out"

                echo
                echo "解析成功。"
                echo
                echo "正在启动..."
                echo

                start

                read -r \
                    -p "按 Enter 返回菜单..." _

                ;;

            2)

                start

                read -r \
                    -p "按 Enter 返回菜单..." _

                ;;

            3)

                systemctl stop "$SERVICE"

                echo
                echo "全局出口已关闭。"
                echo

                read -r \
                    -p "按 Enter 返回菜单..." _

                ;;

            4)

                echo

                systemctl status \
                    "$SERVICE" \
                    --no-pager

                echo

                read -r \
                    -p "按 Enter 返回菜单..." _

                ;;

            5)

                echo
                echo "IPv4："

                curl -4 \
                    --connect-timeout 5 \
                    --max-time 15 \
                    https://api.ipify.org

                echo
                echo
                echo "IPv6："

                curl -6 \
                    --connect-timeout 5 \
                    --max-time 15 \
                    https://api64.ipify.org \
                    2>/dev/null || true

                echo
                echo

                read -r \
                    -p "按 Enter 返回菜单..." _

                ;;

            6)

                echo

                if [ -f "$CONFIG" ]; then

                    cat "$CONFIG"

                else

                    echo "暂无配置。"

                fi

                echo

                read -r \
                    -p "按 Enter 返回菜单..." _

                ;;

            7)

                journalctl \
                    -u "$SERVICE" \
                    -n 80 \
                    --no-pager

                echo

                read -r \
                    -p "按 Enter 返回菜单..." _

                ;;

            8)

                clear

                exit 0

                ;;

            *)

                echo "无效选择。"

                sleep 1

                ;;

        esac

    done
}

menu

EOF

    chmod +x "$VPS_CMD"
}

# ============================================================
# 主程序
# ============================================================

install_dependencies

install_singbox

install_out_command

clear

echo "=========================================="
echo "          VPS 全局出口安装完成"
echo "=========================================="
echo
echo "支持："
echo
echo "# 1. VLESS + WS + TLS"
echo "# 2. VLESS + Reality"
echo "# 3. SOCKS5"
echo
echo "可以直接粘贴完整连接自动解析。"
echo
echo "管理命令："
echo
echo "out"
echo

/usr/local/bin/vps-out
