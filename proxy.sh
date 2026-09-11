#!/usr/bin/env bash

set -u

CONFIG="/etc/sing-box/config.json"
BACKUP_DIR="/etc/sing-box/backup"
SERVICE="sing-box"
BIN="/usr/local/bin/sing-box"
OUT_CMD="/usr/local/bin/out"
VPS_CMD="/usr/local/bin/vps-out"

TMP="/tmp/vps_out_$$"

cleanup() {
    rm -f \
        "$TMP"* \
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
    fi

    OS="${ID:-unknown}"
}

# ============================================================
# 安装依赖
# ============================================================

install_dependencies() {

    detect_os

    echo
    echo "正在安装依赖..."
    echo

    case "$OS" in

        debian|ubuntu)

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

                echo "无法自动识别系统。"
                exit 1

            fi

            ;;

    esac
}

# ============================================================
# 安装 sing-box
# ============================================================

install_singbox() {

    if command -v sing-box >/dev/null 2>&1; then

        SB_BIN="$(command -v sing-box)"

    elif [ -x "$BIN" ]; then

        SB_BIN="$BIN"

    else

        echo
        echo "正在安装 sing-box..."
        echo

        bash <(
            curl -fsSL \
            https://sing-box.app/install.sh
        )

        if command -v sing-box >/dev/null 2>&1; then

            SB_BIN="$(command -v sing-box)"

        elif [ -x "$BIN" ]; then

            SB_BIN="$BIN"

        else

            echo "sing-box 安装失败。"
            exit 1

        fi

    fi

    echo
    echo "sing-box："
    "$SB_BIN" version 2>/dev/null | head -n 1
    echo
}

# ============================================================
# systemd
# ============================================================

install_service() {

    mkdir -p /etc/systemd/system

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Global Proxy
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

create_parser() {

cat > "$TMP_parser.py" <<'PY'
import sys
import json
import urllib.parse
import base64

FILE = sys.argv[1]

with open(FILE, "r", encoding="utf-8") as f:
    raw = f.read().strip()


# ============================================================
# 工具
# ============================================================

def unquote(v):
    return urllib.parse.unquote(v or "")


def qparse(query):
    return urllib.parse.parse_qs(
        query,
        keep_blank_values=True
    )


def qget(q, key, default=""):

    value = q.get(key)

    if not value:
        return default

    return unquote(value[0])


def decode_b64(s):

    s = s.strip()

    try:

        s += "=" * (
            (4 - len(s) % 4) % 4
        )

        return base64.urlsafe_b64decode(
            s
        ).decode()

    except Exception:

        return ""


def truth(v):

    return str(v).lower() in (
        "1",
        "true",
        "yes",
        "on"
    )


def split_userinfo(p):

    username = ""
    password = ""

    if p.username is not None:

        username = unquote(
            p.username
        )

    if p.password is not None:

        password = unquote(
            p.password
        )

    return username, password


def tls_obj(
    q,
    default_server_name=""
):

    server_name = (
        qget(q, "sni")
        or
        qget(q, "peer")
        or
        default_server_name
    )

    obj = {
        "enabled": True
    }

    if server_name:

        obj["server_name"] = server_name

    insecure = qget(q, "allowInsecure")

    if not insecure:
        insecure = qget(q, "insecure")

    if insecure:

        obj["insecure"] = truth(
            insecure
        )

    alpn = qget(q, "alpn")

    if alpn:

        obj["alpn"] = [
            x.strip()
            for x in alpn.split(",")
            if x.strip()
        ]

    fp = qget(q, "fp")

    if fp:

        obj["utls"] = {
            "enabled": True,
            "fingerprint": fp
        }

    return obj


# ============================================================
# VLESS
# ============================================================

def parse_vless(url):

    p = urllib.parse.urlsplit(url)

    q = qparse(p.query)

    uuid = unquote(
        p.username or ""
    )

    if not uuid:
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

    security = qget(
        q,
        "security"
    ).lower()

    typ = qget(
        q,
        "type"
    ).lower()

    out = {

        "type": "vless",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "uuid": uuid

    }

    # --------------------------------------------------------
    # Reality
    # --------------------------------------------------------

    if security == "reality":

        pbk = qget(
            q,
            "pbk"
        )

        sid = qget(
            q,
            "sid"
        )

        if not pbk:

            raise ValueError(
                "Reality 缺少 pbk"
            )

        tls = {

            "enabled": True,

            "server_name":
                qget(q, "sni")
                or p.hostname,

            "utls": {

                "enabled": True,

                "fingerprint":
                    qget(q, "fp")
                    or "chrome"

            },

            "reality": {

                "enabled": True,

                "public_key": pbk,

                "short_id": sid

            }

        }

        out["tls"] = tls

        flow = qget(
            q,
            "flow"
        )

        if flow:

            out["flow"] = flow

        return out, "VLESS + Reality"

    # --------------------------------------------------------
    # WS
    # --------------------------------------------------------

    if typ == "ws":

        path = qget(
            q,
            "path",
            "/"
        )

        host = qget(
            q,
            "host"
        )

        out["tls"] = tls_obj(
            q,
            host or p.hostname
        )

        out["transport"] = {

            "type": "ws",

            "path": path or "/",

            "headers": {}

        }

        if host:

            out["transport"]["headers"][
                "Host"
            ] = host

        flow = qget(
            q,
            "flow"
        )

        if flow:

            out["flow"] = flow

        return out, "VLESS + WS + TLS"

    # --------------------------------------------------------
    # TCP
    # --------------------------------------------------------

    if security == "tls":

        out["tls"] = tls_obj(
            q,
            p.hostname
        )

    flow = qget(
        q,
        "flow"
    )

    if flow:

        out["flow"] = flow

    return out, "VLESS"


# ============================================================
# VMess
# ============================================================

def parse_vmess(url):

    encoded = url[len("vmess://"):]

    decoded = decode_b64(
        encoded
    )

    if not decoded:

        raise ValueError(
            "VMess Base64 解码失败"
        )

    try:

        obj = json.loads(
            decoded
        )

    except:

        raise ValueError(
            "VMess JSON 解析失败"
        )

    server = (
        obj.get("add")
        or obj.get("address")
    )

    port = (
        obj.get("port")
    )

    uuid = (
        obj.get("id")
    )

    if not server or not port or not uuid:

        raise ValueError(
            "VMess 缺少服务器、端口或 UUID"
        )

    try:

        port = int(port)

    except:

        raise ValueError(
            "VMess 端口错误"
        )

    out = {

        "type": "vmess",

        "tag": "proxy",

        "server": server,

        "server_port": port,

        "uuid": uuid

    }

    aid = obj.get("aid")

    if aid:

        try:

            out["alter_id"] = int(aid)

        except:

            pass

    security = (
        obj.get("scy")
        or
        obj.get("cipher")
        or
        "auto"
    )

    if security:

        out["security"] = security

    net = (
        obj.get("net")
        or
        obj.get("type")
        or
        "tcp"
    )

    if net == "ws":

        path = (
            obj.get("path")
            or "/"
        )

        host = (
            obj.get("host")
            or ""
        )

        out["transport"] = {

            "type": "ws",

            "path": path,

            "headers": {}

        }

        if host:

            out["transport"]["headers"][
                "Host"
            ] = host

    if (
        str(
            obj.get("tls", "")
        ).lower()
        in ("tls", "true", "1")
    ):

        out["tls"] = {

            "enabled": True,

            "server_name":
                obj.get("sni")
                or
                obj.get("host")
                or
                server

        }

        fp = obj.get("fp")

        if fp:

            out["tls"]["utls"] = {

                "enabled": True,

                "fingerprint": fp

            }

    return out, "VMess"


# ============================================================
# Trojan
# ============================================================

def parse_trojan(url):

    p = urllib.parse.urlsplit(url)

    q = qparse(p.query)

    password = unquote(
        p.username or ""
    )

    if not password:

        raise ValueError(
            "Trojan 缺少密码"
        )

    if not p.hostname:

        raise ValueError(
            "Trojan 缺少服务器"
        )

    if not p.port:

        raise ValueError(
            "Trojan 缺少端口"
        )

    out = {

        "type": "trojan",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "password": password,

        "tls": tls_obj(
            q,
            p.hostname
        )

    }

    typ = qget(
        q,
        "type"
    ).lower()

    if typ == "ws":

        path = qget(
            q,
            "path",
            "/"
        )

        host = qget(
            q,
            "host"
        )

        out["transport"] = {

            "type": "ws",

            "path": path,

            "headers": {}

        }

        if host:

            out["transport"]["headers"][
                "Host"
            ] = host

    return out, "Trojan"


# ============================================================
# SOCKS5
# ============================================================

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

        "version": "5"

    }

    user, password = split_userinfo(
        p
    )

    if user:

        out["username"] = user

    if password:

        out["password"] = password

    return out, "SOCKS5"


# ============================================================
# HTTP
# ============================================================

def parse_http(url):

    p = urllib.parse.urlsplit(url)

    if not p.hostname:

        raise ValueError(
            "HTTP Proxy 缺少服务器"
        )

    if not p.port:

        raise ValueError(
            "HTTP Proxy 缺少端口"
        )

    out = {

        "type": "http",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port

    }

    user, password = split_userinfo(
        p
    )

    if user:

        out["username"] = user

    if password:

        out["password"] = password

    return out, "HTTP Proxy"


# ============================================================
# Shadowsocks
# ============================================================

def parse_ss(url):

    body = url[
        url.find("://") + 3:
    ]

    body = body.split("#", 1)[0]

    # --------------------------------------------------------
    # ss://method:password@host:port
    # --------------------------------------------------------

    if "@" in body:

        userinfo, hostpart = body.rsplit(
            "@",
            1
        )

        userinfo = unquote(
            userinfo
        )

        if ":" not in userinfo:

            raise ValueError(
                "SS 缺少 method/password"
            )

        method, password = userinfo.split(
            ":",
            1
        )

        hp = urllib.parse.urlsplit(
            "//" + hostpart
        )

        server = hp.hostname
        port = hp.port

    else:

        decoded = decode_b64(
            body
        )

        if not decoded:

            raise ValueError(
                "SS Base64 解码失败"
            )

        if "@" not in decoded:

            raise ValueError(
                "SS 格式错误"
            )

        userinfo, hostpart = decoded.rsplit(
            "@",
            1
        )

        if ":" not in userinfo:

            raise ValueError(
                "SS 缺少 method/password"
            )

        method, password = userinfo.split(
            ":",
            1
        )

        hp = urllib.parse.urlsplit(
            "//" + hostpart
        )

        server = hp.hostname
        port = hp.port

    if not server or not port:

        raise ValueError(
            "SS 缺少服务器或端口"
        )

    out = {

        "type": "shadowsocks",

        "tag": "proxy",

        "server": server,

        "server_port": port,

        "method": method,

        "password": password

    }

    return out, "Shadowsocks"


# ============================================================
# AnyTLS
# ============================================================

def parse_anytls(url):

    p = urllib.parse.urlsplit(url)

    q = qparse(p.query)

    if not p.hostname:

        raise ValueError(
            "AnyTLS 缺少服务器"
        )

    if not p.port:

        raise ValueError(
            "AnyTLS 缺少端口"
        )

    password = unquote(
        p.username or ""
    )

    if not password:

        raise ValueError(
            "AnyTLS 缺少密码"
        )

    out = {

        "type": "anytls",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "password": password,

        "tls": tls_obj(
            q,
            p.hostname
        )

    }

    idle_check = qget(
        q,
        "idle_session_check_interval"
    )

    idle_timeout = qget(
        q,
        "idle_session_timeout"
    )

    min_idle = qget(
        q,
        "min_idle_session"
    )

    if idle_check:

        out[
            "idle_session_check_interval"
        ] = idle_check

    if idle_timeout:

        out[
            "idle_session_timeout"
        ] = idle_timeout

    if min_idle:

        try:

            out["min_idle_session"] = int(
                min_idle
            )

        except:

            pass

    return out, "AnyTLS"


# ============================================================
# Hysteria2
# ============================================================

def parse_hy2(url):

    p = urllib.parse.urlsplit(url)

    q = qparse(p.query)

    if not p.hostname:

        raise ValueError(
            "Hysteria2 缺少服务器"
        )

    if not p.port:

        raise ValueError(
            "Hysteria2 缺少端口"
        )

    password = unquote(
        p.username or ""
    )

    if not password:

        raise ValueError(
            "Hysteria2 缺少密码"
        )

    out = {

        "type": "hysteria2",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "password": password,

        "tls": tls_obj(
            q,
            p.hostname
        )

    }

    # --------------------------------------------------------
    # Obfs
    # --------------------------------------------------------

    obfs = qget(
        q,
        "obfs"
    )

    obfs_password = qget(
        q,
        "obfs-password"
    )

    if not obfs_password:

        obfs_password = qget(
            q,
            "obfs_password"
        )

    if obfs:

        out["obfs"] = {

            "type": obfs,

            "password":
                obfs_password

        }

    # --------------------------------------------------------
    # bandwidth
    # --------------------------------------------------------

    up = qget(
        q,
        "up"
    )

    down = qget(
        q,
        "down"
    )

    if up:

        try:
            out["up_mbps"] = int(up)
        except:
            pass

    if down:

        try:
            out["down_mbps"] = int(down)
        except:
            pass

    network = qget(
        q,
        "network"
    )

    if network:

        out["network"] = network

    return out, "Hysteria2"


# ============================================================
# TUIC
# ============================================================

def parse_tuic(url):

    p = urllib.parse.urlsplit(url)

    q = qparse(p.query)

    if not p.hostname:

        raise ValueError(
            "TUIC 缺少服务器"
        )

    if not p.port:

        raise ValueError(
            "TUIC 缺少端口"
        )

    uuid = unquote(
        p.username or ""
    )

    password = unquote(
        p.password or ""
    )

    if not uuid:

        raise ValueError(
            "TUIC 缺少 UUID"
        )

    out = {

        "type": "tuic",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "uuid": uuid,

        "password": password,

        "tls": tls_obj(
            q,
            p.hostname
        )

    }

    cc = qget(
        q,
        "congestion_control"
    )

    if not cc:

        cc = qget(
            q,
            "congestion-control"
        )

    if cc:

        out[
            "congestion_control"
        ] = cc

    udp_mode = qget(
        q,
        "udp_relay_mode"
    )

    if not udp_mode:

        udp_mode = qget(
            q,
            "udp-relay-mode"
        )

    if udp_mode:

        out[
            "udp_relay_mode"
        ] = udp_mode

    udp_stream = qget(
        q,
        "udp_over_stream"
    )

    if udp_stream:

        out[
            "udp_over_stream"
        ] = truth(
            udp_stream
        )

    zero_rtt = qget(
        q,
        "zero_rtt_handshake"
    )

    if zero_rtt:

        out[
            "zero_rtt_handshake"
        ] = truth(
            zero_rtt
        )

    heartbeat = qget(
        q,
        "heartbeat"
    )

    if heartbeat:

        out[
            "heartbeat"
        ] = heartbeat

    return out, "TUIC"


# ============================================================
# ShadowTLS
# ============================================================

def parse_shadowtls(url):

    p = urllib.parse.urlsplit(url)

    q = qparse(p.query)

    if not p.hostname:

        raise ValueError(
            "ShadowTLS 缺少服务器"
        )

    if not p.port:

        raise ValueError(
            "ShadowTLS 缺少端口"
        )

    password = unquote(
        p.username or ""
    )

    version = qget(
        q,
        "version",
        "3"
    )

    out = {

        "type": "shadowtls",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "version": int(version),

        "password": password,

        "tls": tls_obj(
            q,
            p.hostname
        )

    }

    return out, "ShadowTLS"


# ============================================================
# Hysteria 1
# ============================================================

def parse_hysteria(url):

    p = urllib.parse.urlsplit(url)

    q = qparse(p.query)

    if not p.hostname:

        raise ValueError(
            "Hysteria 缺少服务器"
        )

    if not p.port:

        raise ValueError(
            "Hysteria 缺少端口"
        )

    password = unquote(
        p.username or ""
    )

    if not password:

        raise ValueError(
            "Hysteria 缺少密码"
        )

    out = {

        "type": "hysteria",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "password": password,

        "tls": tls_obj(
            q,
            p.hostname
        )

    }

    up = qget(
        q,
        "upmbps"
    )

    down = qget(
        q,
        "downmbps"
    )

    if up:

        try:
            out["up_mbps"] = int(up)
        except:
            pass

    if down:

        try:
            out["down_mbps"] = int(down)
        except:
            pass

    obfs = qget(
        q,
        "obfs"
    )

    if obfs:

        out["obfs"] = obfs

    return out, "Hysteria"


# ============================================================
# 通用识别
# ============================================================

def parse(url):

    url = url.strip()

    # --------------------------------------------------------
    # VLESS
    # --------------------------------------------------------

    if url.startswith(
        "vless://"
    ):

        return parse_vless(
            url
        )

    # --------------------------------------------------------
    # VMess
    # --------------------------------------------------------

    if url.startswith(
        "vmess://"
    ):

        return parse_vmess(
            url
        )

    # --------------------------------------------------------
    # Trojan
    # --------------------------------------------------------

    if url.startswith(
        "trojan://"
    ):

        return parse_trojan(
            url
        )

    # --------------------------------------------------------
    # SOCKS
    # --------------------------------------------------------

    if url.startswith(
        "socks5://"
    ) or url.startswith(
        "socks5h://"
    ) or url.startswith(
        "socks://"
    ):

        return parse_socks(
            url
        )

    # --------------------------------------------------------
    # HTTP
    # --------------------------------------------------------

    if url.startswith(
        "http://"
    ) or url.startswith(
        "https://"
    ):

        return parse_http(
            url
        )

    # --------------------------------------------------------
    # Shadowsocks
    # --------------------------------------------------------

    if url.startswith(
        "ss://"
    ):

        return parse_ss(
            url
        )

    # --------------------------------------------------------
    # AnyTLS
    # --------------------------------------------------------

    if url.startswith(
        "anytls://"
    ):

        return parse_anytls(
            url
        )

    # --------------------------------------------------------
    # Hysteria2
    # --------------------------------------------------------

    if (
        url.startswith(
            "hysteria2://"
        )
        or
        url.startswith(
            "hy2://"
        )
    ):

        return parse_hy2(
            url
        )

    # --------------------------------------------------------
    # TUIC
    # --------------------------------------------------------

    if url.startswith(
        "tuic://"
    ):

        return parse_tuic(
            url
        )

    # --------------------------------------------------------
    # ShadowTLS
    # --------------------------------------------------------

    if url.startswith(
        "shadowtls://"
    ):

        return parse_shadowtls(
            url
        )

    # --------------------------------------------------------
    # Hysteria
    # --------------------------------------------------------

    if url.startswith(
        "hysteria://"
    ):

        return parse_hysteria(
            url
        )

    # --------------------------------------------------------
    # Base64
    # --------------------------------------------------------

    decoded = decode_b64(
        url
    )

    if decoded:

        decoded = decoded.strip()

        for line in decoded.splitlines():

            line = line.strip()

            if not line:
                continue

            try:

                return parse(
                    line
                )

            except Exception:
                pass

    raise ValueError(
        "无法识别此链接协议"
    )


out, name = parse(
    raw
)

# ============================================================
# 强制 resolver
# ============================================================

out["tag"] = "proxy"

out["domain_resolver"] = \
    "dns-bootstrap"

print(
    json.dumps(
        {
            "name": name,
            "outbound": out
        },
        ensure_ascii=False
    )
)
PY

}

# ============================================================
# 生成配置
# ============================================================

generate_config() {

    PARSED="$1"

    mkdir -p /etc/sing-box
    mkdir -p "$BACKUP_DIR"

    if [ -f "$CONFIG" ]; then

        cp -f \
            "$CONFIG" \
            "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"

    fi

    python3 - "$PARSED" "$CONFIG" <<'PY'

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

    parsed = json.load(f)

outbound = parsed["outbound"]

# ============================================================
# 唯一 proxy
# ============================================================

outbound["tag"] = "proxy"

outbound["domain_resolver"] = \
    "dns-bootstrap"


# ============================================================
# 全新配置
#
# 不读取旧 config
# 不 merge
# 不叠加旧 inbound
#
# 因此不会产生：
# duplicate inbound tag: tun-in
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
# 解析链接
# ============================================================

parse_link() {

    LINK="$1"

    printf '%s' "$LINK" \
        > "$TMP_link"

    if ! python3 \
        "$TMP_parser.py" \
        "$TMP_link" \
        > "$TMP_result" \
        2> "$TMP_error"
    then

        echo
        echo "解析失败："
        cat "$TMP_error"

        return 1

    fi

    return 0
}

# ============================================================
# 启动
# ============================================================

start_proxy() {

    if [ ! -f "$CONFIG" ]; then

        echo
        echo "当前没有配置出口。"
        return 1

    fi

    echo
    echo "正在检查 sing-box 配置..."
    echo

    systemctl stop "$SERVICE" \
        >/dev/null 2>&1 || true

    sleep 1

    if ! "$SB_BIN" check \
        -c "$CONFIG"
    then

        echo
        echo "配置检查失败。"
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

    if systemctl is-active \
        --quiet "$SERVICE"
    then

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

    if systemctl is-active \
        --quiet "$SERVICE"
    then

        echo "状态：运行中"

    else

        echo "状态：已停止"

    fi

    echo

    if [ -f "$CONFIG" ]; then

        python3 - "$CONFIG" <<'PY'

import json
import sys

try:

    with open(
        sys.argv[1],
        encoding="utf-8"
    ) as f:

        c = json.load(f)

    out = c["outbounds"][0]

    print(
        "当前协议：",
        out.get("type", "")
    )

    print(
        "服务器：",
        out.get("server", "")
    )

    print(
        "端口：",
        out.get("server_port", "")
    )

except:

    pass

PY

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
# 选择协议
# ============================================================

select_protocol() {

    clear

    echo "=========================================="
    echo "             VPS 全局出口"
    echo "=========================================="
    echo

    echo "请选择出口协议："
    echo

    echo "# 1.  VLESS + WS + TLS"
    echo "# 2.  VLESS + Reality"
    echo "# 3.  VMess"
    echo "# 4.  Trojan"
    echo "# 5.  SOCKS5"
    echo "# 6.  HTTP Proxy"
    echo "# 7.  Shadowsocks"
    echo "# 8.  Shadowsocks 2022"
    echo "# 9.  AnyTLS"
    echo "# 10. Hysteria2"
    echo "# 11. TUIC"
    echo "# 12. ShadowTLS"
    echo "# 13. Hysteria"
    echo

    read -r \
        -p "请选择 [1-13]：" \
        TYPE

    case "$TYPE" in

        1)
            EXPECTED="VLESS + WS + TLS"
            ;;

        2)
            EXPECTED="VLESS + Reality"
            ;;

        3)
            EXPECTED="VMess"
            ;;

        4)
            EXPECTED="Trojan"
            ;;

        5)
            EXPECTED="SOCKS5"
            ;;

        6)
            EXPECTED="HTTP Proxy"
            ;;

        7)
            EXPECTED="Shadowsocks"
            ;;

        8)
            EXPECTED="Shadowsocks 2022"
            ;;

        9)
            EXPECTED="AnyTLS"
            ;;

        10)
            EXPECTED="Hysteria2"
            ;;

        11)
            EXPECTED="TUIC"
            ;;

        12)
            EXPECTED="ShadowTLS"
            ;;

        13)
            EXPECTED="Hysteria"
            ;;

        *)
            echo
            echo "无效选择。"
            sleep 1
            return
            ;;

    esac

    echo
    echo "当前选择：$EXPECTED"
    echo
    echo "请直接粘贴完整连接："
    echo

    read -r \
        -p "> " \
        LINK

    if [ -z "$LINK" ]; then

        echo
        echo "链接不能为空。"
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
        python3 - "$TMP_result" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8"
) as f:

    print(
        json.load(f)["name"]
    )
PY
)"

    echo
    echo "解析结果：$PARSED_NAME"
    echo

    # ========================================================
    # Shadowsocks 2022 自动识别
    # ========================================================

    if [ "$PARSED_NAME" = "Shadowsocks" ]; then

        METHOD="$(
            python3 - "$TMP_result" <<'PY'
import json
import sys

with open(
    sys.argv[1],
    encoding="utf-8"
) as f:

    print(
        json.load(f)["outbound"].get(
            "method",
            ""
        )
    )
PY
)"

        case "$METHOD" in

            2022-*)
                PARSED_NAME="Shadowsocks 2022"
                ;;

        esac

    fi

    # ========================================================
    # 只做提醒，不阻止
    # ========================================================

    if [ "$EXPECTED" != "$PARSED_NAME" ]; then

        echo
        echo "提示："
        echo "菜单选择：$EXPECTED"
        echo "实际解析：$PARSED_NAME"
        echo
        echo "仍然可以继续使用此链接。"
        echo

        read -r \
            -p "继续？[Y/n]：" \
            ANSWER

        case "$ANSWER" in

            n|N)

                echo "已取消。"
                sleep 1
                return

                ;;

        esac

    fi

    echo
    echo "正在生成全新 sing-box 配置..."
    echo

    generate_config "$TMP_result"

    echo
    echo "配置生成完成。"
    echo

    if start_proxy; then

        echo
        echo "出口协议：$PARSED_NAME"
        echo
        echo "全局代理已生效。"

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
        -n 100 \
        --no-pager

    echo

    read -r \
        -p "按 Enter 返回菜单..." _
}

# ============================================================
# 安装 out
# ============================================================

install_out_command() {

    cat > "$VPS_CMD" <<EOF
#!/usr/bin/env bash
exec "$OUT_CMD"
EOF

    chmod +x "$VPS_CMD"

    cat > "$OUT_CMD" <<EOF
#!/usr/bin/env bash

CONFIG="$CONFIG"
SERVICE="$SERVICE"

SB_BIN="\$(command -v sing-box 2>/dev/null || echo "$BIN")"

TMP="/tmp/out_menu_\$\$"

cleanup() {
    rm -f "\$TMP"* 2>/dev/null || true
}

trap cleanup EXIT

# ============================================================
# 修改出口
# ============================================================

change_proxy() {

    clear

    echo "=========================================="
    echo "              更换出口"
    echo "=========================================="
    echo

    echo "# 1.  VLESS + WS + TLS"
    echo "# 2.  VLESS + Reality"
    echo "# 3.  VMess"
    echo "# 4.  Trojan"
    echo "# 5.  SOCKS5"
    echo "# 6.  HTTP Proxy"
    echo "# 7.  Shadowsocks"
    echo "# 8.  Shadowsocks 2022"
    echo "# 9.  AnyTLS"
    echo "# 10. Hysteria2"
    echo "# 11. TUIC"
    echo "# 12. ShadowTLS"
    echo "# 13. Hysteria"
    echo

    read -r -p "请选择 [1-13]：" TYPE

    case "\$TYPE" in

        1) EXPECTED="VLESS + WS + TLS" ;;
        2) EXPECTED="VLESS + Reality" ;;
        3) EXPECTED="VMess" ;;
        4) EXPECTED="Trojan" ;;
        5) EXPECTED="SOCKS5" ;;
        6) EXPECTED="HTTP Proxy" ;;
        7) EXPECTED="Shadowsocks" ;;
        8) EXPECTED="Shadowsocks 2022" ;;
        9) EXPECTED="AnyTLS" ;;
        10) EXPECTED="Hysteria2" ;;
        11) EXPECTED="TUIC" ;;
        12) EXPECTED="ShadowTLS" ;;
        13) EXPECTED="Hysteria" ;;

        *)
            echo "无效选择。"
            sleep 1
            return
            ;;

    esac

    echo
    echo "请选择：\$EXPECTED"
    echo
    echo "粘贴完整连接："
    echo

    read -r -p "> " LINK

    if [ -z "\$LINK" ]; then

        echo "链接不能为空。"
        sleep 1

        return

    fi

    # ========================================================
    # 使用主脚本重新解析
    # ========================================================

    PARSER="$TMP_parser.py"

    cat > "\$PARSER" <<'PY'

import sys
import json
import urllib.parse
import base64

url = open(
    sys.argv[1],
    encoding="utf-8"
).read().strip()

def uq(v):
    return urllib.parse.unquote(v or "")

def b64(v):

    v += "=" * (
        (4 - len(v) % 4) % 4
    )

    try:
        return base64.urlsafe_b64decode(
            v
        ).decode()
    except:
        return ""

def qget(q,k,d=""):

    x = q.get(k,[d])

    return urllib.parse.unquote(
        x[0]
    )

def tls(q,host):

    o = {
        "enabled": True
    }

    sni = qget(
        q,
        "sni",
        host
    )

    if sni:
        o["server_name"] = sni

    ins = qget(
        q,
        "insecure"
    )

    if ins:
        o["insecure"] = ins in (
            "1",
            "true",
            "yes"
        )

    return o

def parse(u):

    p = urllib.parse.urlsplit(u)

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    scheme = p.scheme.lower()

    if scheme == "vless":

        o = {

            "type":"vless",

            "tag":"proxy",

            "server":p.hostname,

            "server_port":p.port,

            "uuid":uq(p.username),

            "domain_resolver":
                "dns-bootstrap"

        }

        sec=qget(q,"security")

        typ=qget(q,"type")

        if sec=="reality":

            o["tls"]={

                "enabled":True,

                "server_name":
                    qget(q,"sni")
                    or p.hostname,

                "utls":{

                    "enabled":True,

                    "fingerprint":
                        qget(q,"fp")
                        or "chrome"

                },

                "reality":{

                    "enabled":True,

                    "public_key":
                        qget(q,"pbk"),

                    "short_id":
                        qget(q,"sid")

                }

            }

        elif typ=="ws":

            host=qget(q,"host")

            o["tls"]=tls(
                q,
                host or p.hostname
            )

            o["transport"]={

                "type":"ws",

                "path":
                    qget(q,"path","/"),

                "headers":{}

            }

            if host:

                o["transport"][
                    "headers"
                ]["Host"]=host

        else:

            if sec=="tls":

                o["tls"]=tls(
                    q,
                    p.hostname
                )

        return o

    if scheme=="trojan":

        return {

            "type":"trojan",

            "tag":"proxy",

            "server":p.hostname,

            "server_port":p.port,

            "password":uq(p.username),

            "tls":tls(
                q,
                p.hostname
            ),

            "domain_resolver":
                "dns-bootstrap"

        }

    if scheme in (
        "socks",
        "socks5",
        "socks5h"
    ):

        o={

            "type":"socks",

            "tag":"proxy",

            "server":p.hostname,

            "server_port":p.port,

            "version":"5",

            "domain_resolver":
                "dns-bootstrap"

        }

        if p.username:

            o["username"]=uq(
                p.username
            )

        if p.password:

            o["password"]=uq(
                p.password
            )

        return o

    if scheme=="anytls":

        return {

            "type":"anytls",

            "tag":"proxy",

            "server":p.hostname,

            "server_port":p.port,

            "password":uq(
                p.username
            ),

            "tls":tls(
                q,
                p.hostname
            ),

            "domain_resolver":
                "dns-bootstrap"

        }

    if scheme in (
        "hysteria2",
        "hy2"
    ):

        return {

            "type":"hysteria2",

            "tag":"proxy",

            "server":p.hostname,

            "server_port":p.port,

            "password":uq(
                p.username
            ),

            "tls":tls(
                q,
                p.hostname
            ),

            "domain_resolver":
                "dns-bootstrap"

        }

    if scheme=="tuic":

        return {

            "type":"tuic",

            "tag":"proxy",

            "server":p.hostname,

            "server_port":p.port,

            "uuid":uq(
                p.username
            ),

            "password":uq(
                p.password
            ),

            "tls":tls(
                q,
                p.hostname
            ),

            "domain_resolver":
                "dns-bootstrap"

        }

    if scheme=="shadowtls":

        return {

            "type":"shadowtls",

            "tag":"proxy",

            "server":p.hostname,

            "server_port":p.port,

            "version":int(
                qget(q,"version","3")
            ),

            "password":uq(
                p.username
            ),

            "tls":tls(
                q,
                p.hostname
            ),

            "domain_resolver":
                "dns-bootstrap"

        }

    if scheme=="ss":

        body=u[5:]

        if "@" not in body:

            body=b64(
                body
            )

        user,hostpart=body.rsplit(
            "@",
            1
        )

        method,password=user.split(
            ":",
            1
        )

        hp=urllib.parse.urlsplit(
            "//"+hostpart
        )

        return {

            "type":"shadowsocks",

            "tag":"proxy",

            "server":hp.hostname,

            "server_port":hp.port,

            "method":method,

            "password":password,

            "domain_resolver":
                "dns-bootstrap"

        }

    raise ValueError(
        "不支持此协议"
    )

print(
    json.dumps(
        parse(url),
        ensure_ascii=False
    )
)

PY

    printf '%s' "\$LINK" > "\$TMP_link"

    if ! python3 \
        "\$PARSER" \
        "\$TMP_link" \
        > "\$TMP_out" \
        2> "\$TMP_err"
    then

        echo
        echo "解析失败："
        cat "\$TMP_err"
        sleep 2

        return

    fi

    # ========================================================
    # 生成全新配置
    # ========================================================

    python3 - "\$TMP_out" "\$CONFIG" <<'PY'

import sys
import json
import os

src=sys.argv[1]
dst=sys.argv[2]

with open(
    src,
    encoding="utf-8"
) as f:

    out=json.load(f)

out["tag"]="proxy"

out["domain_resolver"]="dns-bootstrap"

config={

    "log":{

        "disabled":False,

        "level":"warn"

    },

    "dns":{

        "servers":[

            {

                "type":"udp",

                "tag":"dns-bootstrap",

                "server":"1.1.1.1",

                "server_port":53

            },

            {

                "type":"udp",

                "tag":"dns-proxy",

                "server":"1.1.1.1",

                "server_port":53,

                "detour":"proxy"

            }

        ],

        "final":"dns-proxy"

    },

    "inbounds":[

        {

            "type":"tun",

            "tag":"tun-in",

            "interface_name":"singtun0",

            "address":[

                "172.19.0.1/30",

                "fdfe:dcba:9876::1/126"

            ],

            "mtu":1500,

            "auto_route":True,

            "strict_route":True

        }

    ],

    "outbounds":[

        out,

        {

            "type":"direct",

            "tag":"direct"

        },

        {

            "type":"block",

            "tag":"block"

        }

    ],

    "route":{

        "auto_detect_interface":True,

        "default_domain_resolver":
            "dns-bootstrap",

        "rules":[

            {

                "protocol":"dns",

                "action":"hijack-dns"

            }

        ],

        "final":"proxy"

    }

}

tmp=dst+".tmp"

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

    f.write("\\n")

os.replace(
    tmp,
    dst
)

PY

    echo
    echo "正在检查配置..."
    echo

    systemctl stop "\$SERVICE" \
        >/dev/null 2>&1 || true

    if ! "\$SB_BIN" check \
        -c "\$CONFIG"
    then

        echo
        echo "配置检查失败。"
        sleep 2

        return

    fi

    systemctl daemon-reload

    systemctl enable "\$SERVICE" \
        >/dev/null 2>&1

    systemctl reset-failed "\$SERVICE" \
        >/dev/null 2>&1

    systemctl restart "\$SERVICE"

    sleep 3

    if systemctl is-active \
        --quiet "\$SERVICE"
    then

        echo
        echo "全局出口已开启。"

    else

        echo
        echo "启动失败。"
        echo

        journalctl \
            -u "\$SERVICE" \
            -n 40 \
            --no-pager

    fi

    echo

    read -r \
        -p "按 Enter 返回菜单..." _
}

# ============================================================
# 菜单
# ============================================================

while true; do

    clear

    echo "=========================================="
    echo "              VPS 出口管理"
    echo "=========================================="
    echo

    if systemctl is-active \
        --quiet "\$SERVICE"
    then

        echo "当前状态：运行中"

    else

        echo "当前状态：已停止"

    fi

    echo

    if [ -f "\$CONFIG" ]; then

        python3 - "\$CONFIG" <<'PY'

import json
import sys

try:

    with open(
        sys.argv[1],
        encoding="utf-8"
    ) as f:

        c=json.load(f)

    o=c["outbounds"][0]

    print(
        "当前协议：",
        o.get("type","")
    )

except:

    pass

PY

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

    case "\$CHOICE" in

        1)

            change_proxy
            ;;

        2)

            if [ -f "\$CONFIG" ]; then

                "\$SB_BIN" check \
                    -c "\$CONFIG" \
                    >/dev/null 2>&1

                if [ "\$?" = "0" ]; then

                    systemctl restart "\$SERVICE"

                    sleep 2

                    echo
                    echo "全局出口已开启。"

                else

                    echo
                    echo "配置检查失败。"

                fi

            else

                echo
                echo "暂无出口配置。"

            fi

            sleep 1
            ;;

        3)

            systemctl stop "\$SERVICE"

            echo
            echo "全局出口已关闭。"

            sleep 1
            ;;

        4)

            systemctl status \
                "\$SERVICE" \
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

            read -r \
                -p "按 Enter 返回菜单..." _

            ;;

        6)

            echo

            if [ -f "\$CONFIG" ]; then

                cat "\$CONFIG"

            else

                echo "暂无配置。"

            fi

            echo

            read -r \
                -p "按 Enter 返回菜单..." _

            ;;

        7)

            journalctl \
                -u "\$SERVICE" \
                -n 100 \
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

            echo
            echo "无效选择。"

            sleep 1

            ;;

    esac

done

EOF

    chmod +x "$OUT_CMD"
    chmod +x "$VPS_CMD"
}

# ============================================================
# 主程序
# ============================================================

install_dependencies

install_singbox

create_parser

install_out_command

clear

echo "=========================================="
echo "        VPS 全局出口脚本安装完成"
echo "=========================================="
echo
echo "支持协议："
echo
echo "1.  VLESS + WS + TLS"
echo "2.  VLESS + Reality"
echo "3.  VMess"
echo "4.  Trojan"
echo "5.  SOCKS5"
echo "6.  HTTP Proxy"
echo "7.  Shadowsocks"
echo "8.  Shadowsocks 2022"
echo "9.  AnyTLS"
echo "10. Hysteria2"
echo "11. TUIC"
echo "12. ShadowTLS"
echo "13. Hysteria"
echo
echo "管理命令："
echo
echo "out"
echo

"$OUT_CMD"
