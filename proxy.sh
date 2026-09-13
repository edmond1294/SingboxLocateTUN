#!/usr/bin/env bash

set -u

CONFIG="/etc/sing-box/config.json"
BACKUP_DIR="/etc/sing-box/backup"
SERVICE="sing-box"
BIN="/usr/local/bin/sing-box"
VPS_CMD="/usr/local/bin/vps-out"
OUT_CMD="/usr/local/bin/out"

TMP="/tmp/vps_out_$$"

cleanup_tmp() {
    rm -f \
        "${TMP}" \
        "${TMP}.link" \
        "${TMP}.json" \
        "${TMP}.py" \
        "${TMP}.err" \
        "${TMP}.out" \
        2>/dev/null || true
}

trap cleanup_tmp EXIT

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行。"
    exit 1
fi

mkdir -p /etc/sing-box
mkdir -p "$BACKUP_DIR"

# ============================================================
# 检测系统
# ============================================================

detect_os() {
    OS="unknown"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="${ID:-unknown}"
    fi
}

# ============================================================
# 安装依赖
# ============================================================

install_dependencies() {

    detect_os

    case "$OS" in

        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive

            apt-get update -y >/dev/null 2>&1 || true

            apt-get install -y \
                curl \
                wget \
                ca-certificates \
                python3 \
                iproute2 \
                procps \
                tar \
                gzip \
                unzip \
                >/dev/null 2>&1
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
                    unzip \
                    >/dev/null 2>&1

            elif command -v yum >/dev/null 2>&1; then

                yum install -y \
                    curl \
                    wget \
                    ca-certificates \
                    python3 \
                    iproute \
                    procps \
                    tar \
                    gzip \
                    unzip \
                    >/dev/null 2>&1

            fi
            ;;

        *)
            if command -v apt-get >/dev/null 2>&1; then

                export DEBIAN_FRONTEND=noninteractive

                apt-get update -y >/dev/null 2>&1 || true

                apt-get install -y \
                    curl \
                    wget \
                    ca-certificates \
                    python3 \
                    iproute2 \
                    procps \
                    tar \
                    gzip \
                    unzip \
                    >/dev/null 2>&1

            fi
            ;;
    esac
}

# ============================================================
# 检测 sing-box
# ============================================================

detect_singbox() {

    SB_BIN=""

    if command -v sing-box >/dev/null 2>&1; then
        SB_BIN="$(command -v sing-box)"
    elif [ -x "$BIN" ]; then
        SB_BIN="$BIN"
    fi

    if [ -n "$SB_BIN" ]; then
        return 0
    fi

    return 1
}

# ============================================================
# 安装 sing-box
# ============================================================

install_singbox() {

    if detect_singbox; then
        return 0
    fi

    echo
    echo "未检测到 sing-box。"
    echo "正在自动安装..."
    echo

    bash <(curl -fsSL https://sing-box.app/install.sh)

    if ! detect_singbox; then
        echo
        echo "sing-box 安装失败。"
        exit 1
    fi

    echo
    echo "sing-box 安装完成。"
}

# ============================================================
# 清理旧 sing-box 服务
# ============================================================

cleanup_old_service() {

    systemctl stop "$SERVICE" >/dev/null 2>&1 || true

    systemctl disable "$SERVICE" >/dev/null 2>&1 || true

    systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true

    # 删除可能存在的旧 service override
    rm -rf \
        /etc/systemd/system/sing-box.service.d \
        /run/systemd/system/sing-box.service.d \
        2>/dev/null || true

    # 清除旧 TUN
    if command -v ip >/dev/null 2>&1; then

        ip link set singtun0 down \
            >/dev/null 2>&1 || true

        ip tuntap del dev singtun0 mode tun \
            >/dev/null 2>&1 || true

        ip link delete singtun0 \
            >/dev/null 2>&1 || true
    fi

    # 清理可能的临时配置
    rm -f \
        /etc/sing-box/config.json.tmp \
        /etc/sing-box/config.json.bak \
        /etc/sing-box/config.backup.json \
        2>/dev/null || true

    # 清理旧 include / fragment 配置
    rm -rf \
        /etc/sing-box/config.d \
        /etc/sing-box/conf.d \
        /etc/sing-box/configs \
        /etc/sing-box/fragments \
        2>/dev/null || true

    systemctl daemon-reload >/dev/null 2>&1 || true
}

# ============================================================
# 写入唯一 systemd 服务
# ============================================================

write_service() {

    mkdir -p /etc/systemd/system

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box VPS Global Outbound
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
# TLS
# ============================================================

tls_config() {

    local query="$1"
    local server="$2"

    python3 - "$query" "$server" <<'PY'
import sys
import urllib.parse
import json

query = sys.argv[1]
server = sys.argv[2]

q = urllib.parse.parse_qs(
    query,
    keep_blank_values=True
)

def get(name, default=""):
    return q.get(name, [default])[0]

sni = get("sni") or get("peer") or server

insecure = get(
    "insecure",
    get("allowInsecure", "0")
)

fp = get("fp")

tls = {
    "enabled": True,
    "server_name": sni
}

if str(insecure).lower() in (
    "1",
    "true",
    "yes",
    "on"
):
    tls["insecure"] = True

if fp:
    tls["utls"] = {
        "enabled": True,
        "fingerprint": fp
    }

print(json.dumps(tls, ensure_ascii=False))
PY
}

# ============================================================
# VLESS
# ============================================================

parse_vless() {

    local link="$1"

    python3 - "$link" <<'PY'
import sys
import json
import urllib.parse

url = sys.argv[1]

p = urllib.parse.urlsplit(url)

if not p.username:
    raise SystemExit("VLESS 缺少 UUID")

if not p.hostname:
    raise SystemExit("VLESS 缺少服务器地址")

if not p.port:
    raise SystemExit("VLESS 缺少服务器端口")

uuid = urllib.parse.unquote(p.username)

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

# ============================================================
# Reality
# ============================================================

if security == "reality":

    pbk = get("pbk")
    sid = get("sid")

    if not pbk:
        raise SystemExit(
            "VLESS Reality 缺少 pbk"
        )

    out = {
        "type": "vless",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "domain_resolver": "dns-bootstrap",
        "tls": {
            "enabled": True,
            "server_name": sni or server,
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

    print(json.dumps({
        "name": "VLESS + Reality",
        "outbound": out
    }, ensure_ascii=False))

    raise SystemExit


# ============================================================
# WS
# ============================================================

if transport == "ws":

    path = urllib.parse.unquote(
        get("path", "/")
    )

    host = get("host")

    out = {
        "type": "vless",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "domain_resolver": "dns-bootstrap",
        "transport": {
            "type": "ws",
            "path": path or "/",
            "headers": {}
        }
    }

    if host:
        out["transport"]["headers"]["Host"] = host

    # TLS
    if security == "tls":

        out["tls"] = {
            "enabled": True,
            "server_name": sni or host or server,
            "utls": {
                "enabled": True,
                "fingerprint": fp
            }
        }

        name = "VLESS + WS + TLS"

    # none
    elif security in (
        "",
        "none"
    ):

        name = "VLESS + WS"

    else:

        raise SystemExit(
            "不支持的 VLESS WS security 类型：" +
            security
        )

    if flow:
        out["flow"] = flow

    print(json.dumps({
        "name": name,
        "outbound": out
    }, ensure_ascii=False))

    raise SystemExit


# ============================================================
# TCP + TLS
# ============================================================

if transport in (
    "",
    "tcp"
) and security == "tls":

    out = {
        "type": "vless",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "domain_resolver": "dns-bootstrap",
        "tls": {
            "enabled": True,
            "server_name": sni or server,
            "utls": {
                "enabled": True,
                "fingerprint": fp
            }
        }
    }

    if flow:
        out["flow"] = flow

    print(json.dumps({
        "name": "VLESS + TLS",
        "outbound": out
    }, ensure_ascii=False))

    raise SystemExit


# ============================================================
# TCP / none
# ============================================================

if transport in (
    "",
    "tcp"
):

    out = {
        "type": "vless",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "domain_resolver": "dns-bootstrap"
    }

    if flow:
        out["flow"] = flow

    print(json.dumps({
        "name": "VLESS + TCP",
        "outbound": out
    }, ensure_ascii=False))

    raise SystemExit


raise SystemExit(
    "不支持的 VLESS 类型"
)
PY
}

# ============================================================
# SOCKS5
# ============================================================

parse_socks() {

    local link="$1"

    python3 - "$link" <<'PY'
import sys
import json
import urllib.parse

url = sys.argv[1]
p = urllib.parse.urlsplit(url)

if not p.hostname:
    raise SystemExit("SOCKS5 缺少服务器地址")

if not p.port:
    raise SystemExit("SOCKS5 缺少端口")

out = {
    "type": "socks",
    "tag": "proxy",
    "server": p.hostname,
    "server_port": p.port,
    "version": "5",
    "domain_resolver": "dns-bootstrap"
}

if p.username:
    out["username"] = urllib.parse.unquote(
        p.username
    )

if p.password:
    out["password"] = urllib.parse.unquote(
        p.password
    )

print(json.dumps({
    "name": "SOCKS5",
    "outbound": out
}, ensure_ascii=False))
PY
}

# ============================================================
# AnyTLS
# ============================================================

parse_anytls() {

    local link="$1"

    python3 - "$link" <<'PY'
import sys
import json
import urllib.parse

url = sys.argv[1]

p = urllib.parse.urlsplit(url)

if not p.hostname:
    raise SystemExit("AnyTLS 缺少服务器地址")

if not p.port:
    raise SystemExit("AnyTLS 缺少端口")

q = urllib.parse.parse_qs(
    p.query,
    keep_blank_values=True
)

def get(name, default=""):
    return q.get(name, [default])[0]

password = ""

if p.username:
    password = urllib.parse.unquote(
        p.username
    )

if not password:
    password = get("password")

if not password:
    raise SystemExit(
        "AnyTLS 缺少 password"
    )

sni = get("sni") or get("peer") or p.hostname

tls = {
    "enabled": True,
    "server_name": sni
}

insecure = get(
    "insecure",
    get("allowInsecure", "0")
)

if str(insecure).lower() in (
    "1",
    "true",
    "yes",
    "on"
):
    tls["insecure"] = True

fp = get("fp")

if fp:
    tls["utls"] = {
        "enabled": True,
        "fingerprint": fp
    }

out = {
    "type": "anytls",
    "tag": "proxy",
    "server": p.hostname,
    "server_port": p.port,
    "password": password,
    "domain_resolver": "dns-bootstrap",
    "tls": tls
}

print(json.dumps({
    "name": "AnyTLS",
    "outbound": out
}, ensure_ascii=False))
PY
}

# ============================================================
# Hysteria2
# ============================================================

parse_hy2() {

    local link="$1"

    python3 - "$link" <<'PY'
import sys
import json
import urllib.parse

url = sys.argv[1]

p = urllib.parse.urlsplit(url)

if not p.hostname:
    raise SystemExit(
        "Hysteria2 缺少服务器地址"
    )

if not p.port:
    raise SystemExit(
        "Hysteria2 缺少端口"
    )

q = urllib.parse.parse_qs(
    p.query,
    keep_blank_values=True
)

def get(name, default=""):
    return q.get(name, [default])[0]

password = ""

if p.username:
    password = urllib.parse.unquote(
        p.username
    )

if p.password:
    password = urllib.parse.unquote(
        p.password
    )

if not password:
    password = urllib.parse.unquote(
        get("password")
    )

if not password:
    raise SystemExit(
        "Hysteria2 缺少 password"
    )

sni = get("sni") or get("peer") or p.hostname

tls = {
    "enabled": True,
    "server_name": sni
}

insecure = get(
    "insecure",
    get("allowInsecure", "0")
)

if str(insecure).lower() in (
    "1",
    "true",
    "yes",
    "on"
):
    tls["insecure"] = True

out = {
    "type": "hysteria2",
    "tag": "proxy",
    "server": p.hostname,
    "server_port": p.port,
    "password": password,
    "domain_resolver": "dns-bootstrap",
    "tls": tls
}

network = get("network")

if network in (
    "tcp",
    "udp"
):
    out["network"] = network

obfs = get("obfs")

obfs_password = get(
    "obfs-password",
    get("obfs_password")
)

if obfs:

    if not obfs_password:
        raise SystemExit(
            "Hysteria2 obfs 缺少密码"
        )

    out["obfs"] = {
        "type": obfs,
        "password": obfs_password
    }

print(json.dumps({
    "name": "Hysteria2",
    "outbound": out
}, ensure_ascii=False))
PY
}

# ============================================================
# TUIC
# ============================================================

parse_tuic() {

    local link="$1"

    python3 - "$link" <<'PY'
import sys
import json
import urllib.parse

url = sys.argv[1]

p = urllib.parse.urlsplit(url)

if not p.hostname:
    raise SystemExit(
        "TUIC 缺少服务器地址"
    )

if not p.port:
    raise SystemExit(
        "TUIC 缺少端口"
    )

q = urllib.parse.parse_qs(
    p.query,
    keep_blank_values=True
)

def get(name, default=""):
    return q.get(name, [default])[0]

uuid = urllib.parse.unquote(
    p.username or ""
)

password = urllib.parse.unquote(
    p.password or ""
)

if not uuid:
    uuid = urllib.parse.unquote(
        get("uuid")
    )

if not password:
    password = urllib.parse.unquote(
        get("password")
    )

if not uuid:
    raise SystemExit(
        "TUIC 缺少 UUID"
    )

if not password:
    raise SystemExit(
        "TUIC 缺少 password"
    )

sni = get("sni") or get("peer") or p.hostname

tls = {
    "enabled": True,
    "server_name": sni
}

insecure = get(
    "insecure",
    get("allowInsecure", "0")
)

if str(insecure).lower() in (
    "1",
    "true",
    "yes",
    "on"
):
    tls["insecure"] = True

out = {
    "type": "tuic",
    "tag": "proxy",
    "server": p.hostname,
    "server_port": p.port,
    "uuid": uuid,
    "password": password,
    "domain_resolver": "dns-bootstrap",
    "tls": tls
}

cc = get("congestion_control")

if cc in (
    "cubic",
    "new_reno",
    "bbr"
):
    out["congestion_control"] = cc

mode = get("udp_relay_mode")

if mode in (
    "native",
    "quic"
):
    out["udp_relay_mode"] = mode

print(json.dumps({
    "name": "TUIC",
    "outbound": out
}, ensure_ascii=False))
PY
}

# ============================================================
# Shadowsocks
# ============================================================

parse_ss() {

    local link="$1"

    python3 - "$link" <<'PY'
import sys
import json
import urllib.parse
import base64

url = sys.argv[1]

p = urllib.parse.urlsplit(url)

def decode_b64(value):
    value = urllib.parse.unquote(
        value.strip()
    )

    value += "=" * (
        (4 - len(value) % 4) % 4
    )

    try:
        return base64.urlsafe_b64decode(
            value
        ).decode()
    except:
        try:
            return base64.b64decode(
                value
            ).decode()
        except:
            return ""

method = ""
password = ""

server = p.hostname
port = p.port

if p.username:

    raw_user = urllib.parse.unquote(
        p.username
    )

    raw_pass = urllib.parse.unquote(
        p.password or ""
    )

    if ":" in raw_user:

        method, password = raw_user.split(
            ":",
            1
        )

    else:

        decoded = decode_b64(
            raw_user
        )

        if ":" in decoded:

            method, password = decoded.split(
                ":",
                1
            )

        else:

            method = raw_user
            password = raw_pass


# 整体 Base64
if not server:

    encoded = url.split(
        "://",
        1
    )[1].split(
        "#",
        1
    )[0]

    decoded = decode_b64(
        encoded
    )

    if decoded:

        decoded = decoded.split(
            "?",
            1
        )[0]

        if "@" in decoded:

            userinfo, hostpart = decoded.rsplit(
                "@",
                1
            )

            if ":" in userinfo:

                method, password = userinfo.split(
                    ":",
                    1
                )

            if hostpart.startswith("["):

                end = hostpart.find("]")

                if end != -1:

                    server = hostpart[
                        1:end
                    ]

                    remain = hostpart[
                        end + 1:
                    ]

                    if remain.startswith(":"):

                        try:
                            port = int(
                                remain[1:]
                            )
                        except:
                            pass

            elif ":" in hostpart:

                server, port_text = hostpart.rsplit(
                    ":",
                    1
                )

                try:
                    port = int(
                        port_text
                    )
                except:
                    pass


q = urllib.parse.parse_qs(
    p.query,
    keep_blank_values=True
)

def get(name, default=""):
    return q.get(name, [default])[0]

if not method:
    method = urllib.parse.unquote(
        get("method")
    )

if not password:
    password = urllib.parse.unquote(
        get("password")
    )

if not server:
    server = urllib.parse.unquote(
        get("server")
    )

if not port and get("port"):

    try:
        port = int(
            get("port")
        )
    except:
        pass

if not server:
    raise SystemExit(
        "Shadowsocks 缺少服务器"
    )

if not port:
    raise SystemExit(
        "Shadowsocks 缺少端口"
    )

if not method:
    raise SystemExit(
        "Shadowsocks 缺少 method"
    )

if password == "":
    raise SystemExit(
        "Shadowsocks 缺少 password"
    )

out = {
    "type": "shadowsocks",
    "tag": "proxy",
    "server": server,
    "server_port": port,
    "method": method,
    "password": password,
    "domain_resolver": "dns-bootstrap"
}

print(json.dumps({
    "name": "Shadowsocks / SS2022",
    "outbound": out
}, ensure_ascii=False))
PY
}

# ============================================================
# 自动解析
# ============================================================

parse_link() {

    local link="$1"

    case "${link,,}" in

        vless://*)
            parse_vless "$link"
            ;;

        socks://*|socks5://*|socks5h://*)
            parse_socks "$link"
            ;;

        anytls://*)
            parse_anytls "$link"
            ;;

        hysteria2://*|hy2://*)
            parse_hy2 "$link"
            ;;

        tuic://*)
            parse_tuic "$link"
            ;;

        ss://*)
            parse_ss "$link"
            ;;

        *)
            echo "无法识别链接。"
            echo
            echo "支持："
            echo "VLESS / SOCKS5 / AnyTLS / Hysteria2 / TUIC / Shadowsocks"
            return 1
            ;;
    esac
}

# ============================================================
# 生成唯一配置
# ============================================================

generate_config() {

    local parsed="$1"

    mkdir -p /etc/sing-box

    if [ -f "$CONFIG" ]; then

        cp -f "$CONFIG" \
            "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json" \
            2>/dev/null || true

    fi

    python3 - "$parsed" "$CONFIG" <<'PY'
import sys
import json
import os

src = sys.argv[1]
dst = sys.argv[2]

with open(
    src,
    "r",
    encoding="utf-8"
) as f:
    data = json.load(f)

outbound = data["outbound"]

outbound["tag"] = "proxy"
outbound["domain_resolver"] = "dns-bootstrap"

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

    chmod 600 "$CONFIG"
}

# ============================================================
# 启动
# ============================================================

start_proxy() {

    if [ ! -f "$CONFIG" ]; then

        echo
        echo "暂无出口配置。"
        echo

        return 1
    fi

    echo
    echo "正在清理旧配置..."
    echo

    cleanup_old_service

    # 确保当前配置只有一个 tun-in
    python3 - "$CONFIG" <<'PY'
import json
import sys

path = sys.argv[1]

with open(
    path,
    "r",
    encoding="utf-8"
) as f:
    data = json.load(f)

inbounds = []
seen = set()

for item in data.get("inbounds", []):

    tag = item.get("tag")

    if tag == "tun-in":

        if tag in seen:
            continue

        seen.add(tag)

    inbounds.append(item)

data["inbounds"] = inbounds

with open(
    path,
    "w",
    encoding="utf-8"
) as f:

    json.dump(
        data,
        f,
        ensure_ascii=False,
        indent=2
    )

    f.write("\n")
PY

    echo "正在检查配置..."
    echo

    if ! "$SB_BIN" check -c "$CONFIG"; then

        echo
        echo "配置检查失败。"
        echo

        return 1
    fi

    # 再次清理可能残留的 TUN
    if command -v ip >/dev/null 2>&1; then

        ip link set singtun0 down \
            >/dev/null 2>&1 || true

        ip tuntap del dev singtun0 mode tun \
            >/dev/null 2>&1 || true

        ip link delete singtun0 \
            >/dev/null 2>&1 || true
    fi

    write_service

    systemctl daemon-reload

    systemctl enable "$SERVICE" \
        >/dev/null 2>&1 || true

    systemctl reset-failed "$SERVICE" \
        >/dev/null 2>&1 || true

    echo
    echo "正在启动 sing-box..."
    echo

    systemctl start "$SERVICE"

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
        -n 50 \
        --no-pager

    return 1
}

# ============================================================
# 停止
# ============================================================

stop_proxy() {

    systemctl stop "$SERVICE" \
        >/dev/null 2>&1 || true

    if command -v ip >/dev/null 2>&1; then

        ip link set singtun0 down \
            >/dev/null 2>&1 || true

        ip tuntap del dev singtun0 mode tun \
            >/dev/null 2>&1 || true

        ip link delete singtun0 \
            >/dev/null 2>&1 || true
    fi

    echo
    echo "全局出口已关闭。"
    echo
}

# ============================================================
# 测试 IPv4
# ============================================================

test_ipv4() {

    local result

    result="$(
        curl \
            -4 \
            -k \
            -sS \
            --connect-timeout 5 \
            --max-time 10 \
            https://1.1.1.1/cdn-cgi/trace \
            2>/dev/null
    )"

    if [ -z "$result" ]; then

        echo "失败"

        return 1
    fi

    local ip

    ip="$(
        printf '%s\n' "$result" |
        sed -n 's/^ip=//p' |
        head -n 1
    )"

    if [ -n "$ip" ]; then
        echo "$ip"
    else
        echo "失败"
        return 1
    fi
}

# ============================================================
# 测试 IPv6
# ============================================================

test_ipv6() {

    local result

    result="$(
        curl \
            -6 \
            -k \
            -sS \
            --connect-timeout 5 \
            --max-time 10 \
            "https://[2606:4700:4700::1111]/cdn-cgi/trace" \
            2>/dev/null
    )"

    if [ -z "$result" ]; then

        echo "失败"

        return 1
    fi

    local ip

    ip="$(
        printf '%s\n' "$result" |
        sed -n 's/^ip=//p' |
        head -n 1
    )"

    if [ -n "$ip" ]; then
        echo "$ip"
    else
        echo "失败"
        return 1
    fi
}

# ============================================================
# 测试出口
# ============================================================

test_proxy() {

    clear

    echo "=========================================="
    echo "              测试当前出口"
    echo "=========================================="
    echo

    if ! systemctl is-active --quiet "$SERVICE"; then

        echo "当前 sing-box 未运行。"
        echo

        read -r \
            -p "按 Enter 返回菜单..." _

        return
    fi

    echo "IPv4："

    IPV4="$(test_ipv4)"

    echo "$IPV4"

    echo
    echo "IPv6："

    IPV6="$(test_ipv6)"

    echo "$IPV6"

    echo
    echo "测试完成。"
    echo

    read -r \
        -p "按 Enter 返回菜单..." _
}

# ============================================================
# 状态
# ============================================================

show_status() {

    clear

    echo "=========================================="
    echo "              VPS 出口状态"
    echo "=========================================="
    echo

    if systemctl is-active --quiet "$SERVICE"; then
        echo "运行状态：运行中"
    else
        echo "运行状态：已停止"
    fi

    echo

    if [ -f "$CONFIG" ]; then

        echo "配置文件："
        echo "$CONFIG"

        echo

        python3 - "$CONFIG" <<'PY'
import json
import sys

try:

    with open(
        sys.argv[1],
        "r",
        encoding="utf-8"
    ) as f:

        data = json.load(f)

    for item in data.get("outbounds", []):

        if item.get("tag") == "proxy":

            print(
                "出口类型：" +
                item.get("type", "unknown")
            )

            print(
                "服务器：" +
                str(item.get("server", ""))
            )

            print(
                "端口：" +
                str(item.get("server_port", ""))
            )

            break

except:
    pass
PY

    fi

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
# 查看日志
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
# 选择出口
# ============================================================

select_proxy() {

    clear

    echo "=========================================="
    echo "             选择出口类型"
    echo "=========================================="
    echo

    echo "# 1. VLESS + WS"
    echo "# 2. VLESS + Reality"
    echo "# 3. SOCKS5"
    echo "# 4. AnyTLS"
    echo "# 5. Hysteria2 / HY2"
    echo "# 6. TUIC"
    echo "# 7. Shadowsocks / SS2022"
    echo

    read -r \
        -p "请选择 [1-7]：" TYPE

    case "$TYPE" in

        1)
            EXPECTED="VLESS + WS"
            ;;

        2)
            EXPECTED="VLESS + Reality"
            ;;

        3)
            EXPECTED="SOCKS5"
            ;;

        4)
            EXPECTED="AnyTLS"
            ;;

        5)
            EXPECTED="Hysteria2"
            ;;

        6)
            EXPECTED="TUIC"
            ;;

        7)
            EXPECTED="Shadowsocks / SS2022"
            ;;

        *)
            echo
            echo "无效选择。"
            sleep 1
            return
            ;;
    esac

    echo
    echo "请选择：$EXPECTED"
    echo
    echo "直接粘贴完整连接："
    echo

    read -r \
        -p "> " \
        LINK

    if [ -z "$LINK" ]; then

        echo
        echo "连接不能为空。"
        sleep 1

        return
    fi

    echo
    echo "正在解析..."
    echo

    if ! parse_link "$LINK" \
        > "$TMP.out" \
        2> "$TMP.err"; then

        echo
        echo "解析失败："
        echo

        cat "$TMP.err" \
            2>/dev/null || true

        echo

        sleep 2

        return
    fi

    if [ ! -s "$TMP.out" ]; then

        echo
        echo "解析失败。"
        sleep 2

        return
    fi

    NAME="$(
        python3 - "$TMP.out" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    "r",
    encoding="utf-8"
) as f:

    data = json.load(f)

print(
    data.get(
        "name",
        "unknown"
    )
)
PY
    )"

    echo "解析成功：$NAME"
    echo

    # 保存旧配置
    if [ -f "$CONFIG" ]; then

        cp -f "$CONFIG" \
            "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json" \
            2>/dev/null || true

    fi

    # 停止旧服务
    systemctl stop "$SERVICE" \
        >/dev/null 2>&1 || true

    # 删除旧 TUN
    if command -v ip >/dev/null 2>&1; then

        ip link set singtun0 down \
            >/dev/null 2>&1 || true

        ip tuntap del dev singtun0 mode tun \
            >/dev/null 2>&1 || true

        ip link delete singtun0 \
            >/dev/null 2>&1 || true
    fi

    echo "正在写入新配置..."

    if ! generate_config "$TMP.out"; then

        echo
        echo "配置生成失败。"
        sleep 2

        return
    fi

    echo
    echo "正在启动..."
    echo

    if start_proxy; then

        echo
        echo "=========================================="
        echo "              配置完成"
        echo "=========================================="
        echo
        echo "出口类型：$NAME"
        echo
        echo "全局出口已开启。"
        echo

    else

        echo
        echo "启动失败。"
        echo

    fi

    read -r \
        -p "按 Enter 返回菜单..." _
}

# ============================================================
# 快速安装
# ============================================================

quick_install() {

    clear

    echo "=========================================="
    echo "              快速安装"
    echo "=========================================="
    echo

    install_dependencies
    install_singbox

    echo
    echo "依赖与 sing-box 已准备完成。"
    echo

    read -r \
        -p "按 Enter 返回菜单..." _
}

# ============================================================
# 安装快捷命令
# ============================================================

install_command() {

    mkdir -p /usr/local/bin

    cat > "$VPS_CMD" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vps-out
EOF

    chmod +x "$VPS_CMD"

    cat > "$OUT_CMD" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vps-out
EOF

    chmod +x "$OUT_CMD"
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

        if systemctl is-active --quiet "$SERVICE"; then
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

                select_proxy
                ;;

            2)

                start_proxy

                echo

                read -r \
                    -p "按 Enter 返回菜单..." _
                ;;

            3)

                stop_proxy

                read -r \
                    -p "按 Enter 返回菜单..." _
                ;;

            4)

                show_status
                ;;

            5)

                test_proxy
                ;;

            6)

                show_config
                ;;

            7)

                show_log
                ;;

            8)

                clear
                exit 0
                ;;

            *)

                echo
                echo "无效选择。"
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# 主程序
# ============================================================

install_dependencies
install_singbox

install_command

clear

echo "=========================================="
echo "          VPS 全局出口安装完成"
echo "=========================================="
echo
echo "支持："
echo
echo "# 1. VLESS + WS"
echo "# 2. VLESS + Reality"
echo "# 3. SOCKS5"
echo "# 4. AnyTLS"
echo "# 5. Hysteria2 / HY2"
echo "# 6. TUIC"
echo "# 7. Shadowsocks / SS2022"
echo
echo "管理命令："
echo
echo "out"
echo

menu
