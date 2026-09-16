# ============================================================
# 安装 out 命令
# ============================================================

install_out_command() {

    # 确保目录存在
    mkdir -p /usr/local/bin

    # ========================================================
    # 安装主程序
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

    printf '%s\n' "$LINK" > "$TMP.link"

    python3 - "$TMP.link" "$TMP.out" <<'PY'
import sys
import json
import base64
import urllib.parse

src = sys.argv[1]
dst = sys.argv[2]

with open(src, encoding="utf-8") as f:
    link = f.read().strip()

def qget(q, key, default=""):
    return q.get(key, [default])[0]

def uq(v):
    return urllib.parse.unquote(v or "")

def decode_b64(s):
    try:
        s = s.strip()
        s += "=" * (-len(s) % 4)
        return base64.urlsafe_b64decode(s).decode()
    except:
        return ""

def parse_vless(url):

    u = urllib.parse.urlsplit(url)

    uuid = u.username or ""
    server = u.hostname or ""
    port = u.port

    q = urllib.parse.parse_qs(u.query)

    if not uuid:
        raise ValueError("VLESS 缺少 UUID")

    if not server:
        raise ValueError("VLESS 缺少服务器")

    if not port:
        raise ValueError("VLESS 缺少端口")

    security = qget(q, "security").lower()

    if not security:
        security = qget(q, "tls").lower()

    transport = qget(q, "type", "tcp").lower()

    fp = qget(q, "fp", "chrome")
    sni = qget(q, "sni", server)
    host = qget(q, "host", "")
    path = uq(qget(q, "path", "/"))

    if transport == "ws":

        outbound = {
            "type": "vless",
            "tag": "proxy",
            "server": server,
            "server_port": port,
            "uuid": uuid,
            "packet_encoding": "xudp",
            "transport": {
                "type": "ws",
                "path": path or "/"
            },
            "domain_resolver": "dns-bootstrap"
        }

        if host:
            outbound["transport"]["headers"] = {
                "Host": host
            }

        if security == "tls":
            outbound["tls"] = {
                "enabled": True,
                "server_name": sni,
                "utls": {
                    "enabled": True,
                    "fingerprint": fp
                }
            }

        elif security in ("", "none"):
            pass

        else:
            raise ValueError(
                "不支持的 VLESS WS security：" + security
            )

        return outbound

    if security == "reality":

        pbk = qget(q, "pbk")
        sid = qget(q, "sid")
        flow = qget(q, "flow")

        if not pbk:
            raise ValueError("Reality 缺少 pbk")

        tls = {
            "enabled": True,
            "server_name": sni,
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

        outbound = {
            "type": "vless",
            "tag": "proxy",
            "server": server,
            "server_port": port,
            "uuid": uuid,
            "tls": tls,
            "domain_resolver": "dns-bootstrap"
        }

        if flow:
            outbound["flow"] = flow

        return outbound

    outbound = {
        "type": "vless",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "domain_resolver": "dns-bootstrap"
    }

    if security == "tls":
        outbound["tls"] = {
            "enabled": True,
            "server_name": sni,
            "utls": {
                "enabled": True,
                "fingerprint": fp
            }
        }

    elif security in ("", "none"):
        pass

    else:
        raise ValueError(
            "不支持的 VLESS security：" + security
        )

    return outbound


def parse_socks(url):

    u = urllib.parse.urlsplit(url)

    server = u.hostname or ""
    port = u.port

    if not server:
        raise ValueError("SOCKS5 缺少服务器")

    if not port:
        raise ValueError("SOCKS5 缺少端口")

    outbound = {
        "type": "socks",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "domain_resolver": "dns-bootstrap"
    }

    if u.username:
        outbound["username"] = urllib.parse.unquote(u.username)

    if u.password:
        outbound["password"] = urllib.parse.unquote(u.password)

    return outbound


def parse_anytls(url):

    u = urllib.parse.urlsplit(url)

    server = u.hostname or ""
    port = u.port
    password = urllib.parse.unquote(u.username or "")

    q = urllib.parse.parse_qs(u.query)

    sni = qget(q, "sni", server)

    if not server:
        raise ValueError("AnyTLS 缺少服务器")

    if not port:
        raise ValueError("AnyTLS 缺少端口")

    if not password:
        raise ValueError("AnyTLS 缺少密码")

    return {
        "type": "anytls",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "password": password,
        "tls": {
            "enabled": True,
            "server_name": sni
        },
        "domain_resolver": "dns-bootstrap"
    }


def parse_hy2(url):

    u = urllib.parse.urlsplit(url)

    server = u.hostname or ""
    port = u.port
    password = urllib.parse.unquote(u.username or "")

    q = urllib.parse.parse_qs(u.query)

    sni = qget(q, "sni", server)

    if not server:
        raise ValueError("Hysteria2 缺少服务器")

    if not port:
        raise ValueError("Hysteria2 缺少端口")

    return {
        "type": "hysteria2",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "password": password,
        "tls": {
            "enabled": True,
            "server_name": sni
        },
        "domain_resolver": "dns-bootstrap"
    }


def parse_tuic(url):

    u = urllib.parse.urlsplit(url)

    server = u.hostname or ""
    port = u.port
    uuid = urllib.parse.unquote(u.username or "")
    password = urllib.parse.unquote(u.password or "")

    q = urllib.parse.parse_qs(u.query)

    sni = qget(q, "sni", server)

    if not server:
        raise ValueError("TUIC 缺少服务器")

    if not port:
        raise ValueError("TUIC 缺少端口")

    return {
        "type": "tuic",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "uuid": uuid,
        "password": password,
        "tls": {
            "enabled": True,
            "server_name": sni
        },
        "domain_resolver": "dns-bootstrap"
    }


def parse_ss(url):

    u = urllib.parse.urlsplit(url)

    server = u.hostname or ""
    port = u.port

    q = urllib.parse.parse_qs(u.query)

    method = qget(q, "method")
    password = qget(q, "password")

    if not method and u.username:
        try:
            raw = base64.urlsafe_b64decode(
                u.username + "=" * (-len(u.username) % 4)
            ).decode()

            if ":" in raw:
                method, password = raw.split(":", 1)
        except:
            pass

    if not server:
        server = qget(q, "server")

    if not port:
        port_text = qget(q, "port")

        if port_text:
            try:
                port = int(port_text)
            except:
                pass

    if not server:
        raise ValueError("Shadowsocks 缺少服务器")

    if not port:
        raise ValueError("Shadowsocks 缺少端口")

    if not method:
        raise ValueError("Shadowsocks 缺少 method")

    if password == "":
        raise ValueError("Shadowsocks 缺少 password")

    return {
        "type": "shadowsocks",
        "tag": "proxy",
        "server": server,
        "server_port": port,
        "method": method,
        "password": password,
        "domain_resolver": "dns-bootstrap"
    }


def parse(url):

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
            except:
                continue

    raise ValueError("无法识别链接")


print(
    json.dumps(
        parse(link),
        ensure_ascii=False,
        indent=2
    )
)
PY

    python3 "$TMP.link" \
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

with open(src, encoding="utf-8") as f:
    outbound = json.load(f)

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

tmp = dst + ".tmp"

with open(tmp, "w", encoding="utf-8") as f:
    json.dump(
        config,
        f,
        ensure_ascii=False,
        indent=2
    )
    f.write("\n")

os.replace(tmp, dst)
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

    if ! "$SB_BIN" check -c "$CONFIG"; then
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
                echo "# 4. AnyTLS"
                echo "# 5. Hysteria2 / HY2"
                echo "# 6. TUIC"
                echo "# 7. Shadowsocks / SS2022"
                echo

                read -r \
                    -p "请选择 [1-7]：" \
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

    # 主程序必须可执行
    chmod 755 "$VPS_CMD"

    # ========================================================
    # out 使用软链接，避免重新安装后 wrapper 出问题
    # ========================================================

    rm -f "$CMD" 2>/dev/null || true

    ln -s "$VPS_CMD" "$CMD"

    chmod 755 "$CMD" 2>/dev/null || true

    # 同时提供 /usr/bin/out，兼容部分系统 PATH
    rm -f /usr/bin/out 2>/dev/null || true

    ln -s "$VPS_CMD" /usr/bin/out

    chmod 755 /usr/bin/out 2>/dev/null || true

    # 清除 Bash 已缓存的旧命令路径
    hash -r 2>/dev/null || true
}
