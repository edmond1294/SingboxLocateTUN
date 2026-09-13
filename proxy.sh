#!/usr/bin/env bash

set -u

CONFIG="/etc/sing-box/config.json"
SB_DIR="/etc/sing-box"
BACKUP_DIR="/etc/sing-box/backup"
SERVICE="sing-box"
CMD="/usr/local/bin/out"
VPS_CMD="/usr/local/bin/vps-out"
TMP="/tmp/vps-out-$$"

mkdir -p "$BACKUP_DIR"

cleanup_tmp() {
    rm -f \
        "$TMP" \
        "$TMP.link" \
        "$TMP.json" \
        "$TMP.py" \
        "$TMP.err" \
        "$TMP.out" \
        "$TMP.tmp" \
        2>/dev/null || true
}

trap cleanup_tmp EXIT

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

    OS="unknown"
    VERSION_ID=""

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="${ID:-unknown}"
        VERSION_ID="${VERSION_ID:-}"
    fi

}

# ============================================================
# init 检测
# ============================================================

detect_init() {

    INIT="none"

    if command -v systemctl >/dev/null 2>&1; then
        INIT="systemd"
        return
    fi

    if command -v rc-service >/dev/null 2>&1; then
        INIT="openrc"
        return
    fi

}

# ============================================================
# 包管理器
# ============================================================

install_dependencies() {

    detect_os

    echo
    echo "正在检测系统..."
    echo "系统：$OS"

    case "$OS" in

        alpine)

            apk update

            apk add \
                bash \
                curl \
                wget \
                ca-certificates \
                python3 \
                iproute2 \
                procps \
                tar \
                gzip \
                unzip \
                jq \
                openrc \
                tzdata \
                coreutils \
                grep \
                sed

            ;;

        ubuntu|debian)

            export DEBIAN_FRONTEND=noninteractive

            apt-get update -y

            apt-get install -y \
                bash \
                curl \
                wget \
                ca-certificates \
                python3 \
                iproute2 \
                procps \
                tar \
                gzip \
                unzip \
                jq \
                coreutils \
                grep \
                sed

            ;;

        centos|rhel|rocky|almalinux|fedora)

            if command -v dnf >/dev/null 2>&1; then

                dnf install -y \
                    bash \
                    curl \
                    wget \
                    ca-certificates \
                    python3 \
                    iproute \
                    procps \
                    tar \
                    gzip \
                    unzip \
                    jq \
                    coreutils \
                    grep \
                    sed

            else

                yum install -y \
                    bash \
                    curl \
                    wget \
                    ca-certificates \
                    python3 \
                    iproute \
                    procps \
                    tar \
                    gzip \
                    unzip \
                    jq \
                    coreutils \
                    grep \
                    sed

            fi

            ;;

        *)

            if command -v apk >/dev/null 2>&1; then

                apk update

                apk add \
                    bash \
                    curl \
                    wget \
                    ca-certificates \
                    python3 \
                    iproute2 \
                    procps \
                    tar \
                    gzip \
                    unzip \
                    jq \
                    openrc \
                    coreutils

            elif command -v apt-get >/dev/null 2>&1; then

                export DEBIAN_FRONTEND=noninteractive

                apt-get update -y

                apt-get install -y \
                    bash \
                    curl \
                    wget \
                    ca-certificates \
                    python3 \
                    iproute2 \
                    procps \
                    tar \
                    gzip \
                    unzip \
                    jq \
                    coreutils

            else

                echo
                echo "无法识别系统，也没有可用的包管理器。"
                exit 1

            fi

            ;;

    esac

    detect_init

    echo
    echo "初始化系统：$INIT"
    echo

}

# ============================================================
# 停止旧服务
# ============================================================

stop_existing_service() {

    detect_init

    if [ "$INIT" = "systemd" ]; then

        systemctl stop sing-box.service \
            >/dev/null 2>&1 || true

    elif [ "$INIT" = "openrc" ]; then

        rc-service sing-box stop \
            >/dev/null 2>&1 || true

    fi

    pkill -x sing-box \
        >/dev/null 2>&1 || true

}

# ============================================================
# 清理旧配置
#
# 重点：
# 不再调用 install_service
# 不再调用 hard_cleanup
#
# 彻底解决：
# duplicate inbound tag: tun-in
# ============================================================

clean_old_config() {

    echo
    echo "正在清理旧 sing-box 配置..."
    echo

    stop_existing_service

    mkdir -p "$BACKUP_DIR"

    # 备份当前主配置
    if [ -f "$CONFIG" ]; then

        cp -f \
            "$CONFIG" \
            "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"

    fi

    # 删除旧配置碎片
    rm -rf \
        "$SB_DIR/conf" \
        "$SB_DIR/configs" \
        "$SB_DIR/config.d" \
        "$SB_DIR/inbounds" \
        "$SB_DIR/outbounds" \
        2>/dev/null || true

    # 删除旧主配置
    rm -f \
        "$CONFIG" \
        "$SB_DIR/config.yaml" \
        "$SB_DIR/config.yml" \
        2>/dev/null || true

    # 清理可能遗留的 sing-box 配置文件
    find "$SB_DIR" \
        -maxdepth 2 \
        -type f \
        \( \
            -name "*.json" \
            -o -name "*.yaml" \
            -o -name "*.yml" \
        \) \
        ! -path "$BACKUP_DIR/*" \
        ! -path "$CONFIG" \
        -delete \
        2>/dev/null || true

    mkdir -p "$SB_DIR"
    mkdir -p "$BACKUP_DIR"

}

# ============================================================
# 查找 sing-box
# ============================================================

find_singbox() {

    SB_BIN=""

    if command -v sing-box >/dev/null 2>&1; then
        SB_BIN="$(command -v sing-box)"
    fi

    if [ -z "$SB_BIN" ] && [ -x "/usr/local/bin/sing-box" ]; then
        SB_BIN="/usr/local/bin/sing-box"
    fi

    if [ -z "$SB_BIN" ] && [ -x "/usr/bin/sing-box" ]; then
        SB_BIN="/usr/bin/sing-box"
    fi

}

# ============================================================
# 安装 sing-box
# ============================================================

install_singbox() {

    find_singbox

    if [ -n "$SB_BIN" ]; then

        echo
        echo "检测到 sing-box："
        "$SB_BIN" version 2>/dev/null | head -n 1
        echo

        return 0

    fi

    detect_os

    echo
    echo "未检测到 sing-box。"
    echo "正在安装..."
    echo

    if [ "$OS" = "alpine" ]; then

        # Alpine 官方包优先
        if apk add sing-box >/dev/null 2>&1; then

            find_singbox

        fi

    fi

    # 如果系统包没有可用版本，使用官方安装器
    if [ -z "${SB_BIN:-}" ]; then

        if command -v curl >/dev/null 2>&1; then

            curl -fsSL \
                https://sing-box.app/install.sh \
                | bash

        else

            wget -qO- \
                https://sing-box.app/install.sh \
                | bash

        fi

    fi

    find_singbox

    if [ -z "$SB_BIN" ]; then

        echo
        echo "sing-box 安装失败。"
        exit 1

    fi

    echo
    echo "sing-box 安装完成："
    "$SB_BIN" version 2>/dev/null | head -n 1
    echo

}

# ============================================================
# TLS 配置
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


def uq(v):
    return urllib.parse.unquote(v or "")


def qget(q, name, default=""):
    return q.get(name, [default])[0]


def decode_b64(v):

    if not v:
        return ""

    v = urllib.parse.unquote(v.strip())
    v += "=" * ((4 - len(v) % 4) % 4)

    try:
        return base64.urlsafe_b64decode(v).decode()
    except Exception:
        try:
            return base64.b64decode(v).decode()
        except Exception:
            return ""


def bool_value(v):

    return str(v).lower() in (
        "1",
        "true",
        "yes",
        "on"
    )


def tls_config(q, server, default_enabled=True):

    security = qget(q, "security").lower()

    if security in (
        "none",
        "null",
        "false",
        "off"
    ):
        return {
            "enabled": False
        }

    insecure = qget(
        q,
        "insecure",
        qget(q, "allowInsecure", "0")
    )

    sni = qget(
        q,
        "sni",
        qget(q, "peer", server)
    )

    tls = {
        "enabled": default_enabled,
        "server_name": sni
    }

    if bool_value(insecure):
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

    # ========================================================
    # Reality
    # ========================================================

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

        out = {
            "type": "vless",
            "tag": "proxy",
            "server": server,
            "server_port": port,
            "uuid": uuid,
            "domain_resolver": "dns-bootstrap",
            "tls": tls
        }

        if flow:
            out["flow"] = flow

        return out, "VLESS + Reality"

    # ========================================================
    # WS
    #
    # 支持：
    #
    # security=tls
    # security=none
    # tls=none
    # tls=0
    #
    # ========================================================

    if transport == "ws":

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

        tls_disabled = (
            security in (
                "",
                "none",
                "null",
                "false",
                "off"
            )
            or
            qget(q, "tls").lower() in (
                "none",
                "false",
                "0",
                "off"
            )
        )

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

        if not tls_disabled:

            out["tls"] = {
                "enabled": True,
                "server_name":
                    sni or ws_host or server,
                "utls": {
                    "enabled": True,
                    "fingerprint": fp
                }
            }

        else:

            out["tls"] = {
                "enabled": False
            }

        if ws_host:

            out["transport"]["headers"]["Host"] = ws_host

        if flow:
            out["flow"] = flow

        if tls_disabled:
            return out, "VLESS + WS"

        return out, "VLESS + WS + TLS"

    # ========================================================
    # VLESS TCP + TLS
    # ========================================================

    if (
        transport in (
            "",
            "tcp"
        )
        and security == "tls"
    ):

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

        return out, "VLESS + TLS"

    # ========================================================
    # VLESS TCP 无 TLS
    # ========================================================

    if (
        transport in (
            "",
            "tcp"
        )
    ):

        out = {
            "type": "vless",
            "tag": "proxy",
            "server": server,
            "server_port": port,
            "uuid": uuid,
            "domain_resolver": "dns-bootstrap",
            "tls": {
                "enabled": False
            }
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
        "domain_resolver": "dns-bootstrap"
    }

    if p.username:
        out["username"] = uq(p.username)

    if p.password:
        out["password"] = uq(p.password)

    return out, "SOCKS5"


# ============================================================
# AnyTLS
# ============================================================

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
        "domain_resolver": "dns-bootstrap",
        "tls": tls_config(
            q,
            p.hostname,
            True
        )
    }, "AnyTLS"


# ============================================================
# Hysteria2
# ============================================================

def parse_hy2(url):

    p = urllib.parse.urlsplit(url)

    if not p.hostname:
        raise ValueError(
            "Hysteria2 缺少服务器地址"
        )

    if not p.port:
        raise ValueError(
            "Hysteria2 缺少服务器端口"
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
        "domain_resolver": "dns-bootstrap",
        "tls": tls_config(
            q,
            p.hostname,
            True
        )
    }

    obfs = qget(
        q,
        "obfs"
    )

    obfs_password = qget(
        q,
        "obfs-password",
        qget(q, "obfs_password")
    )

    if obfs:

        if not obfs_password:
            raise ValueError(
                "Hysteria2 使用 obfs 时缺少 obfs-password"
            )

        out["obfs"] = {
            "type": obfs,
            "password": obfs_password
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
        "domain_resolver": "dns-bootstrap",
        "tls": tls_config(
            q,
            p.hostname,
            True
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
        out["congestion_control"] = cc

    mode = qget(
        q,
        "udp_relay_mode"
    )

    if mode in (
        "native",
        "quic"
    ):
        out["udp_relay_mode"] = mode

    return out, "TUIC"


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

    if p.username:

        raw_user = uq(p.username)
        raw_pass = uq(p.password or "")

        if ":" in raw_user:

            method, password = \
                raw_user.split(":", 1)

        else:

            decoded = decode_b64(
                raw_user
            )

            if ":" in decoded:

                method, password = \
                    decoded.split(":", 1)

            else:

                method = raw_user
                password = raw_pass

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
                    decoded.rsplit("@", 1)

                if ":" in userinfo:

                    method, password = \
                        userinfo.split(":", 1)

                if hostpart.startswith("["):

                    end = hostpart.find("]")

                    if end != -1:

                        server = hostpart[1:end]

                        remain = hostpart[end + 1:]

                        if remain.startswith(":"):

                            try:
                                port = int(
                                    remain[1:]
                                )
                            except Exception:
                                pass

                elif ":" in hostpart:

                    server, port_text = \
                        hostpart.rsplit(":", 1)

                    try:
                        port = int(port_text)
                    except Exception:
                        pass

    if not method:
        method = uq(
            qget(q, "method")
        )

    if not password:
        password = uq(
            qget(q, "password")
        )

    if not server:
        server = uq(
            qget(q, "server")
        )

    if not port:

        port_text = qget(
            q,
            "port"
        )

        if port_text:

            try:
                port = int(port_text)
            except Exception:
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
        "domain_resolver": "dns-bootstrap"
    }, "Shadowsocks / SS2022"


# ============================================================
# 自动识别
# ============================================================

def parse(url):

    url = url.strip()
    lower = url.lower()

    if lower.startswith("vless://"):
        return parse_vless(url)

    if lower.startswith(
        (
            "socks://",
            "socks5://",
            "socks5h://"
        )
    ):
        return parse_socks(url)

    if lower.startswith("anytls://"):
        return parse_anytls(url)

    if lower.startswith(
        (
            "hysteria2://",
            "hy2://"
        )
    ):
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
            except Exception:
                continue

    raise ValueError(
        "无法识别链接"
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
        cat "$TMP.err" 2>/dev/null || true
        return 1

    fi

    return 0
}

# ============================================================
# 写入唯一配置
# ============================================================

write_config() {

    PARSED="$1"

    clean_old_config

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
    data = json.load(f)

outbound = data["outbound"]

# 强制唯一 outbound tag
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

    # ========================================================
    # 这里只有一个 tun
    # tag 永远只有一个 tun-in
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
# 再次确保 inbound tag 唯一
# ============================================================

seen = set()

for inbound in config["inbounds"]:

    tag = inbound.get("tag")

    if tag in seen:
        raise SystemExit(
            "检测到重复 inbound tag: " + str(tag)
        )

    seen.add(tag)

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
# systemd 服务
# ============================================================

setup_systemd() {

    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box VPS Global Proxy
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
# Alpine / OpenRC 服务
# ============================================================

setup_openrc() {

    mkdir -p /etc/init.d

    cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run

name="sing-box"
description="sing-box VPS Global Proxy"

command="$SB_BIN"
command_args="run -c $CONFIG"

command_background="yes"

pidfile="/run/sing-box.pid"

depend() {
    need net
    after firewall
}
EOF

    chmod +x /etc/init.d/sing-box

    rc-update del sing-box default \
        >/dev/null 2>&1 || true

    rc-update add sing-box default \
        >/dev/null 2>&1 || true

}

# ============================================================
# 安装服务
# ============================================================

setup_service() {

    detect_init

    if [ "$INIT" = "systemd" ]; then

        setup_systemd

    elif [ "$INIT" = "openrc" ]; then

        setup_openrc

    else

        echo
        echo "错误：未检测到 systemd 或 OpenRC。"
        return 1

    fi

    return 0
}

# ============================================================
# 服务停止
# ============================================================

service_stop() {

    detect_init

    if [ "$INIT" = "systemd" ]; then

        systemctl stop "$SERVICE" \
            >/dev/null 2>&1 || true

    elif [ "$INIT" = "openrc" ]; then

        rc-service "$SERVICE" stop \
            >/dev/null 2>&1 || true

    fi

}

# ============================================================
# 服务启动
# ============================================================

service_start() {

    detect_init

    if [ "$INIT" = "systemd" ]; then

        systemctl daemon-reload

        systemctl reset-failed "$SERVICE" \
            >/dev/null 2>&1 || true

        systemctl enable "$SERVICE" \
            >/dev/null 2>&1 || true

        systemctl restart "$SERVICE"

        sleep 3

        if systemctl is-active \
            --quiet "$SERVICE"
        then
            return 0
        fi

        return 1

    elif [ "$INIT" = "openrc" ]; then

        rc-service "$SERVICE" restart

        sleep 3

        if rc-service "$SERVICE" status \
            >/dev/null 2>&1
        then
            return 0
        fi

        return 1

    fi

    return 1
}

# ============================================================
# 服务状态
# ============================================================

service_active() {

    detect_init

    if [ "$INIT" = "systemd" ]; then

        systemctl is-active \
            --quiet "$SERVICE"

        return $?

    elif [ "$INIT" = "openrc" ]; then

        rc-service "$SERVICE" status \
            >/dev/null 2>&1

        return $?

    fi

    return 1
}

# ============================================================
# 日志
# ============================================================

show_logs() {

    detect_init

    if [ "$INIT" = "systemd" ]; then

        journalctl \
            -u "$SERVICE" \
            -n 80 \
            --no-pager

    elif [ "$INIT" = "openrc" ]; then

        if [ -f /var/log/messages ]; then

            grep "sing-box" \
                /var/log/messages \
                | tail -n 80

        elif [ -f /var/log/daemon.log ]; then

            grep "sing-box" \
                /var/log/daemon.log \
                | tail -n 80

        else

            echo "Alpine 未找到系统日志文件。"

        fi

    else

        echo "无法读取服务日志。"

    fi
}

# ============================================================
# 配置检查
# ============================================================

check_config() {

    if [ ! -f "$CONFIG" ]; then

        echo
        echo "配置不存在。"
        return 1

    fi

    "$SB_BIN" check \
        -c "$CONFIG"

}

# ============================================================
# 启动出口
# ============================================================

start_proxy() {

    echo
    echo "正在清理旧运行状态..."
    echo

    service_stop

    pkill -x sing-box \
        >/dev/null 2>&1 || true

    sleep 1

    echo
    echo "正在检查配置..."
    echo

    if ! check_config; then

        echo
        echo "配置检查失败。"
        echo

        return 1

    fi

    if ! setup_service; then

        echo
        echo "服务配置失败。"
        return 1

    fi

    if ! service_start; then

        echo
        echo "sing-box 启动失败。"
        echo

        show_logs

        return 1

    fi

    echo
    echo "全局出口已开启。"
    echo

    return 0
}

# ============================================================
# 停止出口
# ============================================================

stop_proxy() {

    service_stop

    echo
    echo "全局出口已关闭。"
    echo
}

# ============================================================
# 测试出口
# ============================================================

test_proxy() {

    echo
    echo "IPv4："

    IPV4=""

    IPV4="$(
        curl -4 \
            -s \
            --connect-timeout 5 \
            --max-time 8 \
            https://api.ipify.org \
            2>/dev/null || true
    )"

    if [ -n "$IPV4" ]; then
        echo "$IPV4"
    else
        echo "IPv4 测试失败或超时"
    fi

    echo
    echo "IPv6："

    IPV6=""

    IPV6="$(
        curl -6 \
            -s \
            --connect-timeout 5 \
            --max-time 8 \
            https://api64.ipify.org \
            2>/dev/null || true
    )"

    if [ -n "$IPV6" ]; then
        echo "$IPV6"
    else
        echo "IPv6 不可用或超时"
    fi

    echo
}

# ============================================================
# 查看状态
# ============================================================

status_proxy() {

    echo

    if service_active; then
        echo "状态：运行中"
    else
        echo "状态：已停止"
    fi

    echo

    echo "初始化系统：$INIT"

    echo

    if [ -f "$CONFIG" ]; then

        echo "当前配置："
        echo "$CONFIG"

    else

        echo "暂无配置。"

    fi

    echo
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

    echo "# 1. VLESS + WS + TLS"
    echo "# 2. VLESS + WS / 无 TLS"
    echo "# 3. VLESS + Reality"
    echo "# 4. SOCKS5"
    echo "# 5. AnyTLS"
    echo "# 6. Hysteria2 / HY2"
    echo "# 7. TUIC"
    echo "# 8. Shadowsocks / SS2022"

    echo

    read -r \
        -p "请选择 [1-8]：" \
        TYPE

    case "$TYPE" in

        1)
            EXPECT="VLESS + WS + TLS"
            ;;

        2)
            EXPECT="VLESS + WS"
            ;;

        3)
            EXPECT="VLESS + Reality"
            ;;

        4)
            EXPECT="SOCKS5"
            ;;

        5)
            EXPECT="AnyTLS"
            ;;

        6)
            EXPECT="Hysteria2"
            ;;

        7)
            EXPECT="TUIC"
            ;;

        8)
            EXPECT="Shadowsocks / SS2022"
            ;;

        *)
            echo
            echo "无效选择。"
            sleep 1
            return
            ;;

    esac

    echo
    echo "你选择：$EXPECT"
    echo
    echo "直接粘贴完整链接："
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

    echo
    echo "解析成功。"
    echo "类型：$PARSED_NAME"
    echo

    # 不再强制要求菜单类型完全一致
    # 避免 security=none / tls=none 被误判

    echo "正在生成新配置..."
    echo

    if ! write_config "$TMP.json"; then

        echo
        echo "配置生成失败。"
        echo

        read -r \
            -p "按 Enter 返回菜单..." _

        return 1

    fi

    echo
    echo "旧配置已清理。"
    echo "新配置已生成。"
    echo

    if ! start_proxy; then

        echo
        echo "启动失败。"
        echo

        read -r \
            -p "按 Enter 返回菜单..." _

        return 1

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
# 查看日志
# ============================================================

show_log() {

    clear

    echo "=========================================="
    echo "              sing-box 日志"
    echo "=========================================="
    echo

    show_logs

    echo

    read -r \
        -p "按 Enter 返回菜单..." _
}

# ============================================================
# 菜单
# ============================================================

menu() {

    while true; do

        clear

        detect_init

        echo "=========================================="
        echo "              VPS 出口管理"
        echo "=========================================="
        echo

        echo "当前状态："

        if service_active; then
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

                clear

                echo "=========================================="
                echo "             开启全局出口"
                echo "=========================================="
                echo

                start_proxy

                echo

                read -r \
                    -p "按 Enter 返回菜单..." _

                ;;

            3)

                clear

                echo "=========================================="
                echo "             关闭全局出口"
                echo "=========================================="
                echo

                stop_proxy

                read -r \
                    -p "按 Enter 返回菜单..." _

                ;;

            4)

                clear

                echo "=========================================="
                echo "                 状态"
                echo "=========================================="

                status_proxy

                read -r \
                    -p "按 Enter 返回菜单..." _

                ;;

            5)

                clear

                echo "=========================================="
                echo "                测试出口"
                echo "=========================================="

                test_proxy

                read -r \
                    -p "按 Enter 返回菜单..." _

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
# 安装 out 快捷命令
# ============================================================

install_out_command() {

    cat > "$VPS_CMD" <<'VPS_EOF'
#!/usr/bin/env bash

exec /usr/local/bin/vps-out-main
VPS_EOF

    chmod +x "$VPS_CMD"

    cat > /usr/local/bin/vps-out-main <<'MAIN_EOF'
#!/usr/bin/env bash

# ============================================================
# 这里重新加载主脚本
# ============================================================

exec /usr/local/bin/vps-out-run
MAIN_EOF

    chmod +x /usr/local/bin/vps-out-main

    # 直接把当前脚本复制为运行主体
    cp -f \
        "$0" \
        /usr/local/bin/vps-out-run

    chmod +x /usr/local/bin/vps-out-run

    cat > "$CMD" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vps-out
EOF

    chmod +x "$CMD"

}

# ============================================================
# 第一次安装时不要让复制后的脚本再次安装自身
# ============================================================

if [ "${VPS_OUT_INTERNAL:-0}" = "1" ]; then

    menu
    exit 0

fi

# ============================================================
# 安装
# ============================================================

install_dependencies
install_singbox

# ============================================================
# 写入真正运行脚本
# ============================================================

SELF="$0"

if [ -f "$SELF" ]; then

    cp -f \
        "$SELF" \
        /usr/local/bin/vps-out-run

    chmod +x \
        /usr/local/bin/vps-out-run

fi

# ============================================================
# out
# ============================================================

cat > "$CMD" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vps-out-run
EOF

chmod +x "$CMD"

# ============================================================
# vps-out
# ============================================================

cat > "$VPS_CMD" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vps-out-run
EOF

chmod +x "$VPS_CMD"

# ============================================================
# 完成
# ============================================================

clear

echo "=========================================="
echo "          VPS 全局出口安装完成"
echo "=========================================="
echo

echo "系统：$OS"
echo "初始化：$INIT"
echo

echo "支持："
echo
echo "# 1. VLESS + WS + TLS"
echo "# 2. VLESS + WS / 无 TLS"
echo "# 3. VLESS + Reality"
echo "# 4. SOCKS5"
echo "# 5. AnyTLS"
echo "# 6. Hysteria2 / HY2"
echo "# 7. TUIC"
echo "# 8. Shadowsocks / SS2022"
echo

echo "快捷命令："
echo
echo "out"
echo

# ============================================================
# 直接进入菜单
# ============================================================

menu
