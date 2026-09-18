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

    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    systemctl kill "$SERVICE" --kill-who=all --signal=SIGKILL >/dev/null 2>&1 || true
    pkill -9 -x sing-box >/dev/null 2>&1 || true
    systemctl revert "$SERVICE" >/dev/null 2>&1 || true
    rm -rf /etc/systemd/system/sing-box.service.d /run/systemd/system/sing-box.service.d 2>/dev/null || true

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
# 统一解析器
# ============================================================

parse_link() {

    LINK="$1"

    printf '%s' "$LINK" > "$TMP.link"

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


# ============================================================
# Base64
# ============================================================

def decode_b64(v):

    v = v.strip()

    v += "=" * ((4 - len(v) % 4) % 4)

    try:
        return base64.urlsafe_b64decode(v).decode()
    except:
        return ""


def b64decode_any(v):

    v = urllib.parse.unquote(v)

    v += "=" * ((4 - len(v) % 4) % 4)

    try:
        return base64.urlsafe_b64decode(v).decode()
    except:
        try:
            return base64.b64decode(v).decode()
        except:
            return ""


def uq(v):
    return urllib.parse.unquote(v or "")


def qget(q, name, default=""):

    return q.get(name, [default])[0]


# ============================================================
# TLS
# ============================================================

def tls_config(q, server, default_enabled=True):

    enabled = default_enabled

    insecure = qget(
        q,
        "insecure",
        qget(q, "allowInsecure", "0")
    )

    server_name = qget(
        q,
        "sni",
        qget(q, "peer", server)
    )

    tls = {
        "enabled": enabled,
        "server_name": server_name
    }

    if str(insecure).lower() in (
        "1",
        "true",
        "yes",
        "on"
    ):
        tls["insecure"] = True

    alpn = qget(q, "alpn")

    if alpn:

        tls["alpn"] = [
            x.strip()
            for x in alpn.split(",")
            if x.strip()
        ]

    fp = qget(q, "fp")

    if fp:

        tls["utls"] = {
            "enabled": True,
            "fingerprint": fp
        }

    return tls


# ============================================================
# VLESS
# ============================================================

def parse_vless(url):

    p = urllib.parse.urlsplit(url)

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

    security = qget(
        q,
        "security"
    ).lower()

    transport = qget(
        q,
        "type"
    ).lower()

    sni = qget(
        q,
        "sni"
    )

    fp = qget(
        q,
        "fp"
    ) or "chrome"

    flow = qget(
        q,
        "flow"
    )

    # --------------------------------------------------------
    # Reality
    # --------------------------------------------------------

    if security == "reality":

        public_key = qget(
            q,
            "pbk"
        )

        short_id = qget(
            q,
            "sid"
        )

        if not public_key:

            raise ValueError(
                "Reality 链接缺少 pbk"
            )

        tls = {

            "enabled": True,

            "server_name":
                sni or server,

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

        out = {

            "type": "vless",

            "tag": "proxy",

            "server": server,

            "server_port": port,

            "uuid": uuid,

            "domain_resolver":
                "dns-bootstrap",

            "tls": tls

        }

        if flow:

            out["flow"] = flow

        return out, "VLESS + Reality"


    # --------------------------------------------------------
    # WS + TLS
    # --------------------------------------------------------

    if (
        transport == "ws"
        and
        security in ("tls", "none", "")
    ):

        path = uq(
            qget(
                q,
                "path",
                "/"
            )
        )

        ws_host = qget(
            q,
            "host"
        )

        out = {

            "type": "vless",

            "tag": "proxy",

            "server": server,

            "server_port": port,

            "uuid": uuid,

            "domain_resolver":
                "dns-bootstrap",

            "tls": tls,

            "transport": {

                "type": "ws",

                "path": path or "/",

                "headers": {}

            }

        }

        if ws_host:

            out["transport"]["headers"]["Host"] = ws_host

        if security == "tls":

            out["tls"] = {
                "enabled": True,
                "server_name": sni or ws_host or server,
                "utls": {
                    "enabled": True,
                    "fingerprint": fp
                }
            }

            name = "VLESS + WS + TLS"

        else:

            name = "VLESS + WS"

        if flow:

            out["flow"] = flow

        return out, name


    # --------------------------------------------------------
    # VLESS TCP + TLS
    # --------------------------------------------------------

    if (
        transport in (
            "",
            "tcp"
        )
        and
        security == "tls"
    ):

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

                }

            }

        }

        if flow:

            out["flow"] = flow

        return out, "VLESS + TLS"


    # --------------------------------------------------------
    # VLESS TCP
    # --------------------------------------------------------

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

            "domain_resolver":
                "dns-bootstrap"

        }

        if flow:

            out["flow"] = flow

        return out, "VLESS + TCP"


    raise ValueError(
        "不支持的 VLESS 类型"
    )


# ============================================================
# SOCKS5
# ============================================================

def parse_socks(url):

    p = urllib.parse.urlsplit(url)

    if not p.hostname:

        raise ValueError(
            "SOCKS5 缺少服务器地址"
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

    return out, "SOCKS5"


# ============================================================
# AnyTLS
# ============================================================

def parse_http(url):

    p = urllib.parse.urlsplit(url)
    if not p.hostname:
        raise ValueError("HTTP 缺少服务器地址")
    if not p.port:
        raise ValueError("HTTP 缺少端口")
    q = urllib.parse.parse_qs(p.query, keep_blank_values=True)
    out = {"type":"http","tag":"proxy","server":p.hostname,"server_port":p.port,"domain_resolver":"dns-bootstrap"}
    if p.username: out["username"] = urllib.parse.unquote(p.username)
    if p.password: out["password"] = urllib.parse.unquote(p.password)
    headers = {}
    for k, vals in q.items():
        if k.lower().startswith("header-") and vals: headers[k[7:]] = vals[-1]
    if headers: out["headers"] = headers
    tls_enabled = p.scheme.lower() in ("https","http+tls") or qget(q,"security").lower()=="tls" or qget(q,"tls").lower() in ("1","true","yes","on")
    if tls_enabled:
        tls={"enabled":True,"server_name":qget(q,"sni") or p.hostname}
        if qget(q,"insecure").lower() in ("1","true","yes","on"): tls["insecure"]=True
        out["tls"]=tls
    return out, "HTTP + TLS" if tls_enabled else "HTTP"


def parse_trojan(url):

    p=urllib.parse.urlsplit(url)
    if not p.hostname: raise ValueError("Trojan 缺少服务器地址")
    if not p.port: raise ValueError("Trojan 缺少端口")
    q=urllib.parse.parse_qs(p.query, keep_blank_values=True)
    password=urllib.parse.unquote(p.username or "") or urllib.parse.unquote(qget(q,"password"))
    if not password: raise ValueError("Trojan 缺少 password")
    out={"type":"trojan","tag":"proxy","server":p.hostname,"server_port":p.port,"password":password,"domain_resolver":"dns-bootstrap","tls":{"enabled":True,"server_name":qget(q,"sni") or qget(q,"peer") or p.hostname}}
    if (qget(q,"allowInsecure") or qget(q,"insecure")).lower() in ("1","true","yes","on"): out["tls"]["insecure"]=True
    alpn=qget(q,"alpn")
    if alpn: out["tls"]["alpn"]=[x.strip() for x in alpn.split(",") if x.strip()]
    network=qget(q,"network").lower()
    if network in ("tcp","udp"): out["network"]=network
    if qget(q,"type").lower()=="ws":
        tr={"type":"ws","path":uq(qget(q,"path","/")) or "/","headers":{}}
        if qget(q,"host"): tr["headers"]["Host"]=qget(q,"host")
        out["transport"]=tr
    return out, "Trojan"


def parse_naive(url):

    p=urllib.parse.urlsplit(url)
    if not p.hostname: raise ValueError("Naive 缺少服务器地址")
    if not p.port: raise ValueError("Naive 缺少端口")
    q=urllib.parse.parse_qs(p.query, keep_blank_values=True)
    username=urllib.parse.unquote(p.username or qget(q,"username"))
    password=urllib.parse.unquote(p.password or qget(q,"password"))
    if not username: raise ValueError("Naive 缺少 username")
    if not password: raise ValueError("Naive 缺少 password")
    out={"type":"naive","tag":"proxy","server":p.hostname,"server_port":p.port,"username":username,"password":password,"domain_resolver":"dns-bootstrap","tls":{"enabled":True,"server_name":qget(q,"sni") or qget(q,"peer") or p.hostname}}
    if (qget(q,"allowInsecure") or qget(q,"insecure")).lower() in ("1","true","yes","on"): out["tls"]["insecure"]=True
    extra={}
    for k,vals in q.items():
        if k.lower().startswith("header-") and vals: extra[k[7:]]=vals[-1]
    if extra: out["extra_headers"]=extra
    if p.scheme.lower()=="naive+quic" or qget(q,"quic").lower() in ("1","true","yes","on"): out["quic"]=True
    cc=qget(q,"quic_congestion_control") or qget(q,"cc")
    if cc: out["quic_congestion_control"]=cc
    return out, "NaiveProxy"


def parse_anytls(url):

    p = urllib.parse.urlsplit(url)

    if not p.hostname:

        raise ValueError(
            "AnyTLS 缺少服务器地址"
        )

    if not p.port:

        raise ValueError(
            "AnyTLS 缺少服务器端口"
        )

    password = ""

    if p.username:

        password = uq(
            p.username
        )

    if not password and p.password:

        password = uq(
            p.password
        )

    if not password:

        qtmp = urllib.parse.parse_qs(
            p.query,
            keep_blank_values=True
        )

        password = uq(
            qget(
                qtmp,
                "password"
            )
        )

    if not password:

        raise ValueError(
            "AnyTLS 缺少 password"
        )

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    out = {

        "type": "anytls",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "password": password,

        "domain_resolver":
            "dns-bootstrap",

        "tls": tls_config(
            q,
            p.hostname,
            True
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

            out[
                "min_idle_session"
            ] = int(min_idle)

        except:

            pass

    return out, "AnyTLS"


# ============================================================
# Hysteria2 / HY2
# ============================================================

def parse_hysteria2(url):

    p = urllib.parse.urlsplit(url)

    if not p.hostname:

        raise ValueError(
            "Hysteria2 缺少服务器地址"
        )

    if not p.port:

        raise ValueError(
            "Hysteria2 缺少服务器端口"
        )

    password = ""

    if p.username:

        password = uq(
            p.username
        )

    if p.password:

        password = uq(
            p.password
        )

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    if not password:

        password = uq(
            qget(
                q,
                "password"
            )
        )

    if not password:

        raise ValueError(
            "Hysteria2 缺少 password"
        )

    out = {

        "type": "hysteria2",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "password": password,

        "domain_resolver":
            "dns-bootstrap",

        "tls": tls_config(
            q,
            p.hostname,
            True
        )

    }

    network = qget(
        q,
        "network"
    )

    if network in (
        "tcp",
        "udp"
    ):

        out["network"] = network

    up = qget(
        q,
        "up_mbps"
    )

    down = qget(
        q,
        "down_mbps"
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

    obfs_password = qget(
        q,
        "obfs-password",
        qget(
            q,
            "obfs_password"
        )
    )

    if obfs:

        if obfs.lower() in (
            "salamander",
            "gecko"
        ):

            if not obfs_password:

                raise ValueError(
                    "Hysteria2 使用 obfs 时缺少 obfs-password"
                )

            out["obfs"] = {

                "type":
                    obfs.lower(),

                "password":
                    obfs_password

            }

    server_ports = qget(
        q,
        "server_ports"
    )

    if server_ports:

        ports = [

            x.strip()

            for x in server_ports.split(",")

            if x.strip()

        ]

        if ports:

            out["server_ports"] = ports

            out.pop(
                "server_port",
                None
            )

    hop_interval = qget(
        q,
        "hop_interval"
    )

    if hop_interval:

        out["hop_interval"] = hop_interval

    hop_interval_max = qget(
        q,
        "hop_interval_max"
    )

    if hop_interval_max:

        out["hop_interval_max"] = \
            hop_interval_max

    return out, "Hysteria2"


# ============================================================
# TUIC
# ============================================================

def parse_tuic(url):

    p = urllib.parse.urlsplit(url)

    if not p.hostname:

        raise ValueError(
            "TUIC 缺少服务器地址"
        )

    if not p.port:

        raise ValueError(
            "TUIC 缺少服务器端口"
        )

    uuid = uq(
        p.username or ""
    )

    password = uq(
        p.password or ""
    )

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    if not uuid:

        uuid = uq(
            qget(
                q,
                "uuid"
            )
        )

    if not password:

        password = uq(
            qget(
                q,
                "password"
            )
        )

    if not uuid:

        raise ValueError(
            "TUIC 缺少 UUID"
        )

    if not password:

        raise ValueError(
            "TUIC 缺少 password"
        )

    out = {

        "type": "tuic",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "uuid": uuid,

        "password": password,

        "domain_resolver":
            "dns-bootstrap",

        "tls": tls_config(
            q,
            p.hostname,
            True
        )

    }

    congestion = qget(
        q,
        "congestion_control"
    )

    if congestion in (
        "cubic",
        "new_reno",
        "bbr"
    ):

        out[
            "congestion_control"
        ] = congestion

    udp_mode = qget(
        q,
        "udp_relay_mode"
    )

    if udp_mode in (
        "native",
        "quic"
    ):

        out[
            "udp_relay_mode"
        ] = udp_mode

    udp_over_stream = qget(
        q,
        "udp_over_stream"
    )

    if udp_over_stream:

        out[
            "udp_over_stream"
        ] = udp_over_stream.lower() in (
            "1",
            "true",
            "yes"
        )

    zero_rtt = qget(
        q,
        "zero_rtt_handshake"
    )

    if zero_rtt:

        out[
            "zero_rtt_handshake"
        ] = zero_rtt.lower() in (
            "1",
            "true",
            "yes"
        )

    heartbeat = qget(
        q,
        "heartbeat"
    )

    if heartbeat:

        out[
            "heartbeat"
        ] = heartbeat

    network = qget(
        q,
        "network"
    )

    if network in (
        "tcp",
        "udp"
    ):

        out["network"] = network

    return out, "TUIC"


# ============================================================
# Shadowsocks
#
# 支持：
#
# ss://BASE64(method:password)@server:port
#
# 例如：
#
# ss://YWVzLTEyOC1nY206ZGExM2ZmZGYwY2U2MDc0OGIzMTc3MDkyYTllMGQzMzY@39.106.22.253:19997?#SS-aes128-19997
#
# 也支持：
#
# ss://method:password@server:port
#
# 以及：
#
# ss://BASE64(method:password@server:port)
#
# 注意：
# SS 没有 username/password 两个独立字段。
# 前面的认证信息是 method:password。
# ============================================================

def parse_ss(url):

    p = urllib.parse.urlsplit(url)

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    method = ""
    password = ""

    server = p.hostname
    port = p.port

    # --------------------------------------------------------
    # SIP002
    #
    # ss://BASE64(method:password)@server:port
    #
    # 重点：
    # p.username 这里通常是 BASE64 字符串，
    # 不能直接当成 method。
    # --------------------------------------------------------

    if p.username:

        raw_user = uq(
            p.username
        )

        raw_pass = uq(
            p.password or ""
        )

        # 直接明文 method:password
        if ":" in raw_user:

            method, password = \
                raw_user.split(
                    ":",
                    1
                )

        else:

            # 标准 SIP002：
            # Base64(method:password)

            decoded = b64decode_any(
                raw_user
            )

            if ":" in decoded:

                method, password = \
                    decoded.split(
                        ":",
                        1
                    )

            else:

                # 某些客户端可能直接把 method
                # 放在 username，密码放在 password

                method = raw_user

                password = raw_pass


    # --------------------------------------------------------
    # 如果 URL 中没有 server
    # 尝试解析完整 Base64
    #
    # ss://BASE64(method:password@server:port)
    # --------------------------------------------------------

    if not server:

        encoded = url.split(
            "://",
            1
        )[1].split(
            "#",
            1
        )[0]

        decoded = b64decode_any(
            encoded
        )

        if decoded:

            # 去除可能的 query
            decoded = decoded.split(
                "?",
                1
            )[0]

            if "@" in decoded:

                userinfo, hostpart = \
                    decoded.rsplit(
                        "@",
                        1
                    )

                if ":" in userinfo:

                    method, password = \
                        userinfo.split(
                            ":",
                            1
                        )

                if hostpart.startswith("["):

                    end = hostpart.find("]")

                    if end != -1:

                        server = hostpart[1:end]

                        remain = hostpart[
                            end + 1:
                        ]

                        if remain.startswith(":"):

                            port_text = \
                                remain[1:]

                            try:

                                port = int(
                                    port_text
                                )

                            except:

                                pass

                elif ":" in hostpart:

                    server, port_text = \
                        hostpart.rsplit(
                            ":",
                            1
                        )

                    try:

                        port = int(
                            port_text
                        )

                    except:

                        pass


    # --------------------------------------------------------
    # query 参数
    # --------------------------------------------------------

    if not method:

        method = uq(
            qget(
                q,
                "method"
            )
        )

    if not password:

        password = uq(
            qget(
                q,
                "password"
            )
        )

    if not server:

        server = uq(
            qget(
                q,
                "server"
            )
        )

    if not port:

        port_text = qget(
            q,
            "port"
        )

        if port_text:

            try:

                port = int(
                    port_text
                )

            except:

                pass


    # --------------------------------------------------------
    # 最终检查
    # --------------------------------------------------------

    if not server:

        raise ValueError(
            "Shadowsocks 缺少服务器地址"
        )

    if not port:

        raise ValueError(
            "Shadowsocks 缺少端口"
        )

    if not method:

        raise ValueError(
            "Shadowsocks 缺少加密方式"
        )

    if password == "":

        raise ValueError(
            "Shadowsocks 缺少密码"
        )


    # --------------------------------------------------------
    # 生成 sing-box SS outbound
    # --------------------------------------------------------

    out = {

        "type": "shadowsocks",

        "tag": "proxy",

        "server": server,

        "server_port": port,

        "method": method,

        "password": password,

        "domain_resolver":
            "dns-bootstrap"

    }

    plugin = qget(
        q,
        "plugin"
    )

    plugin_opts = qget(
        q,
        "plugin_opts"
    )

    if plugin:

        out["plugin"] = plugin

    if plugin_opts:

        out["plugin_opts"] = \
            plugin_opts

    network = qget(
        q,
        "network"
    )

    if network in (
        "tcp",
        "udp"
    ):

        out["network"] = network

    return out, "Shadowsocks / SS2022"


# ============================================================
# 自动识别
# ============================================================

def parse(url):

    url = url.strip()

    lower = url.lower()

    if lower.startswith(
        "vless://"
    ):

        return parse_vless(url)

    if lower.startswith(
        (
            "socks://",
            "socks5://",
            "socks5h://"
        )
    ):

        return parse_socks(url)

    if lower.startswith(("http://", "https://", "http+tls://")):

        return parse_http(url)

    if lower.startswith("trojan://"):

        return parse_trojan(url)

    if lower.startswith(("naive://", "naive+https://", "naive+quic://")):

        return parse_naive(url)

    if lower.startswith(
        "anytls://"
    ):

        return parse_anytls(url)

    if lower.startswith(
        (
            "hysteria2://",
            "hy2://"
        )
    ):

        return parse_hysteria2(url)

    if lower.startswith(
        "tuic://"
    ):

        return parse_tuic(url)

    if lower.startswith(
        "ss://"
    ):

        return parse_ss(url)

    decoded = decode_b64(url)

    if decoded:

        for line in decoded.splitlines():

            line = line.strip()

            if not line:

                continue

            try:

                return parse(line)

            except:

                continue

    raise ValueError(
        "无法识别链接。"
        "支持 VLESS / HTTP / Trojan / NaiveProxy / SOCKS5 / "
        "AnyTLS / Hysteria2 / TUIC / Shadowsocks"
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

outbound["tag"] = "proxy"

outbound["domain_resolver"] = \
    "dns-bootstrap"

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

    systemctl stop "$SERVICE" >/dev/null 2>&1 || true

    rm -rf /etc/systemd/system/sing-box.service.d /run/systemd/system/sing-box.service.d /etc/sing-box/config.d /etc/sing-box/conf.d /etc/sing-box/configs /etc/sing-box/fragments 2>/dev/null || true

    if command -v ip >/dev/null 2>&1; then
        ip link set singtun0 down >/dev/null 2>&1 || true
        ip tuntap del dev singtun0 mode tun >/dev/null 2>&1 || true
        ip link delete singtun0 >/dev/null 2>&1 || true
    fi

    python3 - "$CONFIG" <<'PY'
import json, sys, os
path=sys.argv[1]
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f: d=json.load(f)
    for key in ("inbounds","outbounds"):
        seen=set(); clean=[]
        for x in d.get(key,[]):
            tag=x.get("tag") if isinstance(x,dict) else None
            if tag and tag in seen: continue
            if tag: seen.add(tag)
            clean.append(x)
        d[key]=clean
    dns=d.get("dns",{})
    if isinstance(dns,dict):
        seen=set(); clean=[]
        for x in dns.get("servers",[]):
            tag=x.get("tag") if isinstance(x,dict) else None
            if tag and tag in seen: continue
            if tag: seen.add(tag)
            clean.append(x)
        dns["servers"]=clean
    tmp=path+".repair.tmp"
    with open(tmp,"w",encoding="utf-8") as f:
        json.dump(d,f,ensure_ascii=False,indent=2); f.write("\n")
    os.replace(tmp,path)
PY

    echo
    echo "正在检查配置..."
    echo

    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    systemctl kill "$SERVICE" --kill-who=all --signal=SIGKILL >/dev/null 2>&1 || true
    pkill -9 -x sing-box >/dev/null 2>&1 || true
    systemctl revert "$SERVICE" >/dev/null 2>&1 || true
    rm -rf /etc/systemd/system/sing-box.service.d /run/systemd/system/sing-box.service.d 2>/dev/null || true

    sleep 1

    install_service

    if ! "$SB_BIN" check \
        -c "$CONFIG"
    then

        echo
        echo "配置检查失败。"
        echo

        return 1
    fi

    systemctl daemon-reload

    systemctl enable "$SERVICE" \
        >/dev/null 2>&1

    systemctl reset-failed "$SERVICE" \
        >/dev/null 2>&1

    systemctl start "$SERVICE"

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
    echo "# 4. HTTP / HTTPS"
    echo "# 5. Trojan"
    echo "# 6. NaiveProxy"
    echo "# 7. AnyTLS"
    echo "# 8. Hysteria2 / HY2"
    echo "# 9. TUIC"
    echo "# 10. Shadowsocks / SS2022"
    echo

    read -r \
        -p "请选择 [1-10]：" \
        TYPE

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

        4)
            EXPECTED="HTTP"
            ;;

        5)
            EXPECTED="Trojan"
            ;;

        6)
            EXPECTED="NaiveProxy"
            ;;

        7)
            EXPECTED="AnyTLS"
            ;;

        8)
            EXPECTED="Hysteria2"
            ;;

        9)
            EXPECTED="TUIC"
            ;;

        10)
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
    echo "你选择：$EXPECTED"
    echo
    echo "请直接粘贴完整连接："
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
# 安装 out 命令
# ============================================================

install_out_command() {

    cat > "$CMD" <<'EOF'
#!/usr/bin/env bash

if [ -t 0 ] && [ -t 1 ]; then
    exec /usr/local/bin/vps-out "$@"
fi

if [ -e /dev/tty ]; then
    exec /usr/local/bin/vps-out "$@" </dev/tty >/dev/tty 2>/dev/tty
fi

exec /usr/local/bin/vps-out "$@"
EOF

    chmod +x "$CMD"

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
    return urllib.parse.unquote(v or "")


def decode_b64(v):

    v = v.strip()

    v += "=" * ((4 - len(v) % 4) % 4)

    try:
        return base64.urlsafe_b64decode(v).decode()
    except:
        try:
            return base64.b64decode(v).decode()
        except:
            return ""


def qget(q, name, default=""):
    return q.get(name, [default])[0]


def tls(q, server):

    sni = qget(
        q,
        "sni",
        qget(
            q,
            "peer",
            server
        )
    )

    insecure = qget(
        q,
        "insecure",
        qget(
            q,
            "allowInsecure",
            "0"
        )
    )

    out = {

        "enabled": True,

        "server_name": sni

    }

    if str(insecure).lower() in (
        "1",
        "true",
        "yes",
        "on"
    ):

        out["insecure"] = True

    fp = qget(
        q,
        "fp"
    )

    if fp:

        out["utls"] = {

            "enabled": True,

            "fingerprint": fp

        }

    return out


def parse_vless(url):

    p = urllib.parse.urlsplit(url)

    if not p.username:
        raise ValueError("VLESS 缺少 UUID")

    if not p.hostname:
        raise ValueError("VLESS 缺少服务器")

    if not p.port:
        raise ValueError("VLESS 缺少端口")

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    security = qget(
        q,
        "security"
    ).lower()

    typ = qget(
        q,
        "type"
    ).lower()

    sni = qget(
        q,
        "sni"
    )

    fp = qget(
        q,
        "fp"
    ) or "chrome"

    uuid = uq(
        p.username
    )

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

        out = {

            "type": "vless",

            "tag": "proxy",

            "server": p.hostname,

            "server_port": p.port,

            "uuid": uuid,

            "domain_resolver":
                "dns-bootstrap",

            "tls": {

                "enabled": True,

                "server_name":
                    sni or p.hostname,

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

        flow = qget(
            q,
            "flow"
        )

        if flow:
            out["flow"] = flow

        return out


    if typ == "ws" and security in ("tls", "none", ""):

        path = uq(
            qget(
                q,
                "path",
                "/"
            )
        )

        host = qget(
            q,
            "host"
        )

        out = {

            "type": "vless",

            "tag": "proxy",

            "server": p.hostname,

            "server_port": p.port,

            "uuid": uuid,

            "domain_resolver":
                "dns-bootstrap",

            "transport": {

                "type": "ws",

                "path": path,

                "headers": {}

            }

        }

        if host:

            out[
                "transport"
            ][
                "headers"
            ][
                "Host"
            ] = host

        if security == "tls":
            out["tls"] = {
                "enabled": True,
                "server_name": sni or host or p.hostname,
                "utls": {
                    "enabled": True,
                    "fingerprint": fp
                }
            }

        flow = qget(
            q,
            "flow"
        )

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
            uq(p.username)

    if p.password:

        out["password"] = \
            uq(p.password)

    return out


def parse_http(url):

    p = urllib.parse.urlsplit(url)
    if not p.hostname: raise ValueError("HTTP 缺少服务器地址")
    if not p.port: raise ValueError("HTTP 缺少端口")
    q = urllib.parse.parse_qs(p.query, keep_blank_values=True)
    out={"type":"http","tag":"proxy","server":p.hostname,"server_port":p.port,"domain_resolver":"dns-bootstrap"}
    if p.username: out["username"]=urllib.parse.unquote(p.username)
    if p.password: out["password"]=urllib.parse.unquote(p.password)
    tls_enabled=p.scheme.lower() in ("https","http+tls") or qget(q,"security").lower()=="tls" or qget(q,"tls").lower() in ("1","true","yes","on")
    if tls_enabled:
        out["tls"]={"enabled":True,"server_name":qget(q,"sni") or p.hostname}
        if qget(q,"insecure").lower() in ("1","true","yes","on"): out["tls"]["insecure"]=True
    return out


def parse_trojan(url):

    p=urllib.parse.urlsplit(url)
    if not p.hostname: raise ValueError("Trojan 缺少服务器地址")
    if not p.port: raise ValueError("Trojan 缺少端口")
    q=urllib.parse.parse_qs(p.query, keep_blank_values=True)
    password=urllib.parse.unquote(p.username or "") or urllib.parse.unquote(qget(q,"password"))
    if not password: raise ValueError("Trojan 缺少 password")
    out={"type":"trojan","tag":"proxy","server":p.hostname,"server_port":p.port,"password":password,"domain_resolver":"dns-bootstrap","tls":{"enabled":True,"server_name":qget(q,"sni") or qget(q,"peer") or p.hostname}}
    if (qget(q,"allowInsecure") or qget(q,"insecure")).lower() in ("1","true","yes","on"): out["tls"]["insecure"]=True
    alpn=qget(q,"alpn")
    if alpn: out["tls"]["alpn"]=[x.strip() for x in alpn.split(",") if x.strip()]
    network=qget(q,"network").lower()
    if network in ("tcp","udp"): out["network"]=network
    if qget(q,"type").lower()=="ws":
        tr={"type":"ws","path":urllib.parse.unquote(qget(q,"path","/")) or "/","headers":{}}
        if qget(q,"host"): tr["headers"]["Host"]=qget(q,"host")
        out["transport"]=tr
    return out


def parse_naive(url):

    p=urllib.parse.urlsplit(url)
    if not p.hostname: raise ValueError("Naive 缺少服务器地址")
    if not p.port: raise ValueError("Naive 缺少端口")
    q=urllib.parse.parse_qs(p.query, keep_blank_values=True)
    username=urllib.parse.unquote(p.username or qget(q,"username"))
    password=urllib.parse.unquote(p.password or qget(q,"password"))
    if not username: raise ValueError("Naive 缺少 username")
    if not password: raise ValueError("Naive 缺少 password")
    out={"type":"naive","tag":"proxy","server":p.hostname,"server_port":p.port,"username":username,"password":password,"domain_resolver":"dns-bootstrap","tls":{"enabled":True,"server_name":qget(q,"sni") or qget(q,"peer") or p.hostname}}
    if (qget(q,"allowInsecure") or qget(q,"insecure")).lower() in ("1","true","yes","on"): out["tls"]["insecure"]=True
    if p.scheme.lower()=="naive+quic" or qget(q,"quic").lower() in ("1","true","yes","on"): out["quic"]=True
    cc=qget(q,"quic_congestion_control") or qget(q,"cc")
    if cc: out["quic_congestion_control"]=cc
    return out


def parse_anytls(url):

    p = urllib.parse.urlsplit(url)

    if not p.hostname:
        raise ValueError(
            "AnyTLS 缺少服务器"
        )

    if not p.port:
        raise ValueError(
            "AnyTLS 缺少端口"
        )

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    password = uq(
        p.username or
        qget(q, "password")
    )

    if not password:
        raise ValueError(
            "AnyTLS 缺少 password"
        )

    return {

        "type": "anytls",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "password": password,

        "domain_resolver":
            "dns-bootstrap",

        "tls": tls(
            q,
            p.hostname
        )

    }


def parse_hy2(url):

    p = urllib.parse.urlsplit(url)

    if not p.hostname:
        raise ValueError(
            "Hysteria2 缺少服务器"
        )

    if not p.port:
        raise ValueError(
            "Hysteria2 缺少端口"
        )

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    password = uq(
        p.username or
        qget(q, "password")
    )

    if not password:
        raise ValueError(
            "Hysteria2 缺少 password"
        )

    out = {

        "type": "hysteria2",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "password": password,

        "domain_resolver":
            "dns-bootstrap",

        "tls": tls(
            q,
            p.hostname
        )

    }

    obfs = qget(
        q,
        "obfs"
    )

    obfs_password = qget(
        q,
        "obfs-password"
    )

    if obfs:

        if not obfs_password:

            raise ValueError(
                "Hysteria2 缺少 obfs-password"
            )

        out["obfs"] = {

            "type": obfs,

            "password":
                obfs_password

        }

    network = qget(
        q,
        "network"
    )

    if network in (
        "tcp",
        "udp"
    ):

        out["network"] = network

    return out


def parse_tuic(url):

    p = urllib.parse.urlsplit(url)

    if not p.hostname:
        raise ValueError(
            "TUIC 缺少服务器"
        )

    if not p.port:
        raise ValueError(
            "TUIC 缺少端口"
        )

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    uuid = uq(
        p.username or
        qget(q, "uuid")
    )

    password = uq(
        p.password or
        qget(q, "password")
    )

    if not uuid:
        raise ValueError(
            "TUIC 缺少 UUID"
        )

    if not password:
        raise ValueError(
            "TUIC 缺少 password"
        )

    out = {

        "type": "tuic",

        "tag": "proxy",

        "server": p.hostname,

        "server_port": p.port,

        "uuid": uuid,

        "password": password,

        "domain_resolver":
            "dns-bootstrap",

        "tls": tls(
            q,
            p.hostname
        )

    }

    cc = qget(
        q,
        "congestion_control"
    )

    if cc in (
        "cubic",
        "new_reno",
        "bbr"
    ):

        out[
            "congestion_control"
        ] = cc

    mode = qget(
        q,
        "udp_relay_mode"
    )

    if mode in (
        "native",
        "quic"
    ):

        out[
            "udp_relay_mode"
        ] = mode

    return out


# ============================================================
# Shadowsocks
# ============================================================

def parse_ss(url):

    p = urllib.parse.urlsplit(url)

    q = urllib.parse.parse_qs(
        p.query,
        keep_blank_values=True
    )

    method = ""
    password = ""

    server = p.hostname
    port = p.port

    # --------------------------------------------------------
    # SIP002
    #
    # ss://BASE64(method:password)@server:port
    # --------------------------------------------------------

    if p.username:

        raw_user = uq(
            p.username
        )

        raw_pass = uq(
            p.password or ""
        )

        # 明文 method:password
        if ":" in raw_user:

            method, password = \
                raw_user.split(
                    ":",
                    1
                )

        else:

            # 标准 SS：
            # username 本身是 Base64(method:password)

            decoded = decode_b64(
                raw_user
            )

            if ":" in decoded:

                method, password = \
                    decoded.split(
                        ":",
                        1
                    )

            else:

                method = raw_user

                password = raw_pass


    # --------------------------------------------------------
    # 整体 Base64
    #
    # ss://BASE64(method:password@server:port)
    # --------------------------------------------------------

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

                userinfo, hostpart = \
                    decoded.rsplit(
                        "@",
                        1
                    )

                if ":" in userinfo:

                    method, password = \
                        userinfo.split(
                            ":",
                            1
                        )

                if hostpart.startswith("["):

                    end = hostpart.find("]")

                    if end != -1:

                        server = hostpart[1:end]

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

                    server, port_text = \
                        hostpart.rsplit(
                            ":",
                            1
                        )

                    try:

                        port = int(
                            port_text
                        )

                    except:

                        pass


    # --------------------------------------------------------
    # query
    # --------------------------------------------------------

    if not method:

        method = uq(
            qget(
                q,
                "method"
            )
        )

    if not password:

        password = uq(
            qget(
                q,
                "password"
            )
        )

    if not server:

        server = uq(
            qget(
                q,
                "server"
            )
        )

    if not port:

        port_text = qget(
            q,
            "port"
        )

        if port_text:

            try:

                port = int(
                    port_text
                )

            except:

                pass


    if not server:

        raise ValueError(
            "Shadowsocks 缺少服务器"
        )

    if not port:

        raise ValueError(
            "Shadowsocks 缺少端口"
        )

    if not method:

        raise ValueError(
            "Shadowsocks 缺少 method"
        )

    if password == "":

        raise ValueError(
            "Shadowsocks 缺少 password"
        )


    return {

        "type": "shadowsocks",

        "tag": "proxy",

        "server": server,

        "server_port": port,

        "method": method,

        "password": password,

        "domain_resolver":
            "dns-bootstrap"

    }


def parse(url):

    lower = url.lower()

    if lower.startswith("vless://"):
        return parse_vless(url)

    if lower.startswith(("socks://", "socks5://", "socks5h://")):
        return parse_socks(url)

    if lower.startswith(("http://", "https://", "http+tls://")):
        return parse_http(url)

    if lower.startswith("trojan://"):
        return parse_trojan(url)

    if lower.startswith(("naive://", "naive+https://", "naive+quic://")):
        return parse_naive(url)

    if lower.startswith("anytls://"):
        return parse_anytls(url)

    if lower.startswith(("hysteria2://", "hy2://")):
        return parse_hy2(url)

    if lower.startswith("tuic://"):
        return parse_tuic(url)

    if lower.startswith("ss://"):
        return parse_ss(url)

    decoded = decode_b64(url)

    if decoded:

        for line in decoded.splitlines():

            line = line.strip()

            if not line:
                continue

            try:
                return parse(line)
            except:
                continue

    raise ValueError(
        "无法识别链接"
    )


print(
    json.dumps(
        parse(link),
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

outbound["tag"] = "proxy"

outbound["domain_resolver"] = \
    "dns-bootstrap"

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

    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    systemctl kill "$SERVICE" --kill-who=all --signal=SIGKILL >/dev/null 2>&1 || true
    pkill -9 -x sing-box >/dev/null 2>&1 || true
    systemctl revert "$SERVICE" >/dev/null 2>&1 || true

    rm -rf /etc/systemd/system/sing-box.service.d /run/systemd/system/sing-box.service.d /etc/sing-box/config.d /etc/sing-box/conf.d /etc/sing-box/configs /etc/sing-box/fragments 2>/dev/null || true

    if command -v ip >/dev/null 2>&1; then
        ip link set singtun0 down >/dev/null 2>&1 || true
        ip tuntap del dev singtun0 mode tun >/dev/null 2>&1 || true
        ip link delete singtun0 >/dev/null 2>&1 || true
    fi

    python3 - "$CONFIG" <<'PY'
import json, sys, os
path=sys.argv[1]
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f: d=json.load(f)
    for key in ("inbounds","outbounds"):
        seen=set(); clean=[]
        for x in d.get(key,[]):
            tag=x.get("tag") if isinstance(x,dict) else None
            if tag and tag in seen: continue
            if tag: seen.add(tag)
            clean.append(x)
        d[key]=clean
    dns=d.get("dns",{})
    if isinstance(dns,dict):
        seen=set(); clean=[]
        for x in dns.get("servers",[]):
            tag=x.get("tag") if isinstance(x,dict) else None
            if tag and tag in seen: continue
            if tag: seen.add(tag)
            clean.append(x)
        dns["servers"]=clean
    tmp=path+".repair.tmp"
    with open(tmp,"w",encoding="utf-8") as f:
        json.dump(d,f,ensure_ascii=False,indent=2); f.write("\n")
    os.replace(tmp,path)
PY

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

    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/sing-box.service <<VPS_SERVICE_EOF
[Unit]
Description=sing-box VPS Global Outbound
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$SB_BIN run -c $CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
VPS_SERVICE_EOF

    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true

    systemctl enable "$SERVICE" \
        >/dev/null 2>&1

    systemctl reset-failed "$SERVICE" \
        >/dev/null 2>&1

    systemctl start "$SERVICE"

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
                echo "# 4. AnyTLS"
                echo "# 5. Hysteria2 / HY2"
                echo "# 6. TUIC"
                echo "# 7. Shadowsocks / SS2022"
                echo

                read -r \
                    -p "请选择 [1-10]：" \
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

                    4)
                        EXPECT="AnyTLS"
                        ;;

                    5)
                        EXPECT="Hysteria2"
                        ;;

                    6)
                        EXPECT="TUIC"
                        ;;

                    7)
                        EXPECT="Shadowsocks / SS2022"
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
echo "# 4. AnyTLS"
echo "# 5. Hysteria2 / HY2"
echo "# 6. TUIC"
echo "# 7. Shadowsocks / SS2022"
echo
echo "可以直接粘贴完整连接自动解析。"
echo
echo "管理命令："
echo
echo "out"
echo
/usr/local/bin/vps-out
