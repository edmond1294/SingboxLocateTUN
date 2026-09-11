#!/bin/bash

CONFIG="/etc/sing-box/config.json"
BACKUP="/etc/sing-box/config.json.bak"

BIN="/usr/local/bin/vps-out"
LINK="/usr/local/bin/out"

mkdir -p /etc/sing-box
mkdir -p /etc/vps-out

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 用户运行此脚本"
    exit 1
fi


install_basic() {

    clear

    echo "=============================="
    echo "        安装系统依赖"
    echo "=============================="
    echo

    if command -v apt-get >/dev/null 2>&1; then

        apt-get update -y >/dev/null 2>&1

        apt-get install -y \
            curl \
            wget \
            ca-certificates \
            unzip \
            iproute2 \
            python3 \
            >/dev/null 2>&1

    elif command -v dnf >/dev/null 2>&1; then

        dnf install -y \
            curl \
            wget \
            ca-certificates \
            unzip \
            iproute \
            python3 \
            >/dev/null 2>&1

    elif command -v yum >/dev/null 2>&1; then

        yum install -y \
            curl \
            wget \
            ca-certificates \
            unzip \
            iproute \
            python3 \
            >/dev/null 2>&1

    elif command -v apk >/dev/null 2>&1; then

        apk add --no-cache \
            curl \
            wget \
            ca-certificates \
            unzip \
            iproute2 \
            python3 \
            >/dev/null 2>&1

    else

        echo "无法识别系统包管理器"
        return 1

    fi

    echo "系统依赖安装完成"

    sleep 1
}


install_singbox() {

    clear

    echo "=============================="
    echo "      安装 / 更新 sing-box"
    echo "=============================="
    echo

    if ! command -v curl >/dev/null 2>&1; then
        install_basic
    fi

    echo "正在安装 / 更新 sing-box..."
    echo

    curl -fsSL https://sing-box.app/install.sh | sh

    echo

    if command -v sing-box >/dev/null 2>&1; then

        echo "sing-box 安装成功"
        echo

        sing-box version

        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable sing-box >/dev/null 2>&1

    else

        echo "sing-box 安装失败"

        read -r -p "按回车返回..."
        return 1

    fi

    echo
    read -r -p "按回车返回..."
}


check_install() {

    mkdir -p /etc/sing-box

    if ! command -v sing-box >/dev/null 2>&1; then

        clear

        echo "检测到 sing-box 尚未安装"
        echo
        echo "首次运行将自动安装所需组件"
        echo

        install_basic
        install_singbox

    fi
}


create_config_vless_ws() {

    NODE="$1"

    python3 - "$NODE" "$CONFIG" <<'PY'

import sys
import json
import os

from urllib.parse import urlsplit, parse_qs, unquote


node = sys.argv[1]
config_file = sys.argv[2]


try:

    u = urlsplit(node)

    if u.scheme.lower() != "vless":
        raise Exception("不是 VLESS 链接")

    if not u.hostname:
        raise Exception("缺少服务器地址")

    if not u.port:
        raise Exception("缺少服务器端口")

    uuid = unquote(u.username or "")

    if not uuid:
        raise Exception("缺少 UUID")

    q = parse_qs(u.query)

    security = q.get("security", [""])[0].lower()
    transport_type = q.get("type", [""])[0].lower()

    if security != "tls":
        raise Exception("此节点不是 TLS")

    if transport_type != "ws":
        raise Exception("此节点不是 WS")

    sni = unquote(q.get("sni", [""])[0])
    host = unquote(q.get("host", [""])[0])
    path = unquote(q.get("path", ["/"])[0])

    fingerprint = q.get("fp", ["chrome"])[0]

    outbound = {
        "type": "vless",
        "tag": "proxy",

        "server": u.hostname,
        "server_port": u.port,

        "uuid": uuid,

        "tls": {
            "enabled": True,
            "server_name": sni if sni else u.hostname,

            "utls": {
                "enabled": True,
                "fingerprint": fingerprint
            }
        },

        "transport": {
            "type": "ws",
            "path": path
        }
    }


    if host:

        outbound["transport"]["headers"] = {
            "Host": host
        }


    config = {

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

                    "detour": "proxy"
                }

            ],

            "final": "dns-remote",

            "strategy": "prefer_ipv4"
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

                "auto_route": True,

                "strict_route": True,

                "stack": "system"
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

            "final": "proxy"
        }

    }


    ssh_client = os.environ.get("SSH_CLIENT", "").split()

    if ssh_client:

        client_ip = ssh_client[0]

        exclude = [

            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",

            "127.0.0.0/8",
            "169.254.0.0/16",

            "::1/128",
            "fc00::/7",
            "fe80::/10"
        ]

        if ":" in client_ip:

            exclude.append(
                client_ip + "/128"
            )

        else:

            exclude.append(
                client_ip + "/32"
            )

        config["inbounds"][0]["route_exclude_address"] = exclude


    with open(
        config_file,
        "w",
        encoding="utf-8"
    ) as f:

        json.dump(
            config,
            f,
            indent=2,
            ensure_ascii=False
        )


except Exception as e:

    print("解析失败:", e)

    sys.exit(1)

PY
}


create_config_socks() {

    NODE="$1"

    python3 - "$NODE" "$CONFIG" <<'PY'

import sys
import json
import os

from urllib.parse import urlsplit, unquote


node = sys.argv[1]
config_file = sys.argv[2]


try:

    u = urlsplit(node)

    if u.scheme.lower() not in ("socks", "socks5"):
        raise Exception("不是 SOCKS5 链接")

    if not u.hostname:
        raise Exception("缺少服务器地址")

    if not u.port:
        raise Exception("缺少服务器端口")


    outbound = {

        "type": "socks",

        "tag": "proxy",

        "server": u.hostname,

        "server_port": u.port,

        "version": "5"
    }


    if u.username:

        outbound["username"] = unquote(
            u.username
        )


    if u.password:

        outbound["password"] = unquote(
            u.password
        )


    config = {

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

                    "detour": "proxy"
                }

            ],

            "final": "dns-remote",

            "strategy": "prefer_ipv4"
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

                "auto_route": True,

                "strict_route": True,

                "stack": "system"
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

            "final": "proxy"
        }

    }


    ssh_client = os.environ.get(
        "SSH_CLIENT",
        ""
    ).split()


    if ssh_client:

        client_ip = ssh_client[0]

        exclude = [

            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",

            "127.0.0.0/8",
            "169.254.0.0/16",

            "::1/128",
            "fc00::/7",
            "fe80::/10"
        ]


        if ":" in client_ip:

            exclude.append(
                client_ip + "/128"
            )

        else:

            exclude.append(
                client_ip + "/32"
            )


        config["inbounds"][0][
            "route_exclude_address"
        ] = exclude


    with open(
        config_file,
        "w",
        encoding="utf-8"
    ) as f:

        json.dump(
            config,
            f,
            indent=2,
            ensure_ascii=False
        )


except Exception as e:

    print("解析失败:", e)

    sys.exit(1)

PY
}


create_config_reality() {

    NODE="$1"

    python3 - "$NODE" "$CONFIG" <<'PY'

import sys
import json
import os

from urllib.parse import urlsplit, parse_qs, unquote


node = sys.argv[1]
config_file = sys.argv[2]


try:

    u = urlsplit(node)

    if u.scheme.lower() != "vless":
        raise Exception("不是 VLESS 链接")

    if not u.hostname:
        raise Exception("缺少服务器地址")

    if not u.port:
        raise Exception("缺少服务器端口")


    uuid = unquote(
        u.username or ""
    )


    if not uuid:
        raise Exception("缺少 UUID")


    q = parse_qs(
        u.query
    )


    security = q.get(
        "security",
        [""]
    )[0].lower()


    if security != "reality":
        raise Exception(
            "此节点不是 Reality"
        )


    sni = unquote(
        q.get("sni", [""])[0]
    )

    fingerprint = q.get(
        "fp",
        ["chrome"]
    )[0]

    public_key = q.get(
        "pbk",
        [""]
    )[0]

    short_id = q.get(
        "sid",
        [""]
    )[0]

    flow = q.get(
        "flow",
        [""]
    )[0]


    if not sni:
        raise Exception(
            "缺少 sni"
        )


    if not public_key:
        raise Exception(
            "缺少 pbk"
        )


    tls = {

        "enabled": True,

        "server_name": sni,

        "utls": {

            "enabled": True,

            "fingerprint": fingerprint
        },

        "reality": {

            "enabled": True,

            "public_key": public_key
        }
    }


    if short_id:

        tls["reality"]["short_id"] = short_id


    outbound = {

        "type": "vless",

        "tag": "proxy",

        "server": u.hostname,

        "server_port": u.port,

        "uuid": uuid,

        "tls": tls
    }


    if flow:

        outbound["flow"] = flow


    config = {

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

                    "detour": "proxy"
                }

            ],

            "final": "dns-remote",

            "strategy": "prefer_ipv4"
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

                "auto_route": True,

                "strict_route": True,

                "stack": "system"
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

            "final": "proxy"
        }

    }


    ssh_client = os.environ.get(
        "SSH_CLIENT",
        ""
    ).split()


    if ssh_client:

        client_ip = ssh_client[0]

        exclude = [

            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",

            "127.0.0.0/8",
            "169.254.0.0/16",

            "::1/128",
            "fc00::/7",
            "fe80::/10"
        ]


        if ":" in client_ip:

            exclude.append(
                client_ip + "/128"
            )

        else:

            exclude.append(
                client_ip + "/32"
            )


        config["inbounds"][0][
            "route_exclude_address"
        ] = exclude


    with open(
        config_file,
        "w",
        encoding="utf-8"
    ) as f:

        json.dump(
            config,
            f,
            indent=2,
            ensure_ascii=False
        )


except Exception as e:

    print("解析失败:", e)

    sys.exit(1)

PY
}


apply_config() {

    clear

    echo "=============================="
    echo "        检查代理配置"
    echo "=============================="
    echo

    if [ ! -f "$CONFIG" ]; then

        echo "配置文件不存在"

        read -r -p "按回车返回..."

        return

    fi


    if ! sing-box check -c "$CONFIG"; then

        echo
        echo "配置检查失败"
        echo

        if [ -f "$BACKUP" ]; then

            cp -f "$BACKUP" "$CONFIG"

            echo "已恢复旧配置"

        fi

        read -r -p "按回车返回..."

        return

    fi


    echo
    echo "配置检查通过"
    echo


    systemctl daemon-reload >/dev/null 2>&1

    systemctl enable sing-box >/dev/null 2>&1

    systemctl restart sing-box


    sleep 2


    if systemctl is-active --quiet sing-box; then

        echo "全局代理已启动"

        echo
        echo "VPS 出站流量已通过 sing-box TUN 转发"

    else

        echo "sing-box 启动失败"

        echo

        systemctl status sing-box \
            --no-pager \
            -l

    fi


    echo

    read -r -p "按回车返回..."
}


configure() {

    clear

    echo "=============================="
    echo "          代理类型"
    echo "=============================="
    echo

    echo "1. VLESS + WS + TLS"
    echo "2. SOCKS5"
    echo "3. VLESS + Reality"
    echo "0. 返回"

    echo

    read -r -p "请选择: " TYPE

    clear


    case "$TYPE" in

        1)

            echo "=============================="
            echo "      VLESS + WS + TLS"
            echo "=============================="
            echo

            echo "请粘贴完整 VLESS 节点："
            echo

            read -r NODE


            if [ -z "$NODE" ]; then

                echo
                echo "节点不能为空"

                read -r -p "按回车返回..."

                return

            fi


            if [ -f "$CONFIG" ]; then

                cp -f "$CONFIG" "$BACKUP"

            fi


            create_config_vless_ws "$NODE"


            if [ $? -ne 0 ]; then

                echo
                echo "节点解析失败"

                if [ -f "$BACKUP" ]; then
                    cp -f "$BACKUP" "$CONFIG"
                fi

                read -r -p "按回车返回..."

                return

            fi


            apply_config

            ;;


        2)

            echo "=============================="
            echo "            SOCKS5"
            echo "=============================="
            echo

            echo "支持："
            echo "socks5://用户名:密码@服务器:端口"
            echo

            echo "请粘贴完整 SOCKS5 节点："
            echo

            read -r NODE


            if [ -z "$NODE" ]; then

                echo
                echo "节点不能为空"

                read -r -p "按回车返回..."

                return

            fi


            if [ -f "$CONFIG" ]; then

                cp -f "$CONFIG" "$BACKUP"

            fi


            create_config_socks "$NODE"


            if [ $? -ne 0 ]; then

                echo
                echo "节点解析失败"

                if [ -f "$BACKUP" ]; then
                    cp -f "$BACKUP" "$CONFIG"
                fi

                read -r -p "按回车返回..."

                return

            fi


            apply_config

            ;;


        3)

            echo "=============================="
            echo "        VLESS + Reality"
            echo "=============================="
            echo

            echo "请粘贴完整 VLESS Reality 节点："
            echo

            read -r NODE


            if [ -z "$NODE" ]; then

                echo
                echo "节点不能为空"

                read -r -p "按回车返回..."

                return

            fi


            if [ -f "$CONFIG" ]; then

                cp -f "$CONFIG" "$BACKUP"

            fi


            create_config_reality "$NODE"


            if [ $? -ne 0 ]; then

                echo
                echo "节点解析失败"

                if [ -f "$BACKUP" ]; then
                    cp -f "$BACKUP" "$CONFIG"
                fi

                read -r -p "按回车返回..."

                return

            fi


            apply_config

            ;;


        0)

            return

            ;;


        *)

            echo "无效选项"

            read -r -p "按回车返回..."

            ;;

    esac
}


disable_proxy() {

    clear

    echo "=============================="
    echo "        关闭全局代理"
    echo "=============================="
    echo

    systemctl stop sing-box >/dev/null 2>&1


    if ip link show singtun0 >/dev/null 2>&1; then

        ip link delete singtun0 >/dev/null 2>&1

    fi


    echo "全局代理已关闭"

    echo

    read -r -p "按回车返回..."
}


show_status() {

    clear

    echo "=============================="
    echo "          当前状态"
    echo "=============================="
    echo


    if command -v sing-box >/dev/null 2>&1; then

        echo "sing-box：已安装"

        echo

        sing-box version

    else

        echo "sing-box：未安装"

    fi


    echo


    if systemctl is-active --quiet sing-box; then

        echo "代理状态：运行中"

    else

        echo "代理状态：已停止"

    fi


    echo


    if ip link show singtun0 >/dev/null 2>&1; then

        echo "TUN 状态：已创建"

    else

        echo "TUN 状态：未创建"

    fi


    echo


    if [ -f "$CONFIG" ]; then

        echo "配置文件：存在"

    else

        echo "配置文件：不存在"

    fi


    echo

    read -r -p "按回车返回..."
}


install_menu() {

    clear

    echo "=============================="
    echo "       安装 / 更新"
    echo "=============================="
    echo

    echo "1. 安装 / 更新 sing-box"
    echo "2. 安装系统依赖"
    echo "0. 返回"

    echo

    read -r -p "请选择: " CHOICE

    clear


    case "$CHOICE" in

        1)

            install_basic
            install_singbox

            ;;


        2)

            install_basic

            echo

            read -r -p "按回车返回..."

            ;;


        0)

            return

            ;;


        *)

            echo "无效选项"

            read -r -p "按回车返回..."

            ;;

    esac
}


check_install


while true; do

    clear

    echo "=============================="
    echo "        VPS 全局出口代理"
    echo "=============================="
    echo

    echo "1. 配置全局代理"
    echo "2. 关闭全局代理"
    echo "3. 查看状态"
    echo "4. 安装 / 更新"
    echo "0. 退出"

    echo

    read -r -p "请选择: " MENU

    clear


    case "$MENU" in

        1)

            configure

            ;;


        2)

            disable_proxy

            ;;


        3)

            show_status

            ;;


        4)

            install_menu

            ;;


        0)

            clear

            exit 0

            ;;


        *)

            echo "无效选项"

            read -r -p "按回车返回..."

            ;;

    esac

done
