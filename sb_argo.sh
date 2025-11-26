#!/bin/bash
# =========================================================
# Sing-box + Argo 终极版 (V5.2 输入逻辑修复)
# 修复: 在 curl 管道模式下无法正确读取用户选择的问题
# =========================================================

# === 变量 ===
PORT=8001
WORKDIR="/etc/singbox_argo"
CONFIG_FILE="$WORKDIR/config.json"
SB_BIN="/usr/local/bin/sing-box"
CF_BIN="/usr/local/bin/cloudflared"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# === 1. 环境准备 ===
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请使用 root 运行!${PLAIN}"
        exit 1
    fi
}

detect_system() {
    if [ -f /etc/alpine-release ]; then
        OS="alpine"
        INIT="openrc"
        PKG_CMD="apk add --no-cache"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        INIT="systemd"
        PKG_CMD="apt-get update && apt-get install -y"
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        INIT="systemd"
        PKG_CMD="yum install -y"
    else
        echo -e "${RED}不支持的系统${PLAIN}"
        exit 1
    fi
}

detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  SB_ARCH="amd64"; CF_ARCH="amd64" ;;
        aarch64) SB_ARCH="arm64"; CF_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac
}

# === 2. 128M 内存救命优化 ===
optimize_env() {
    MEM=$(free -m | awk '/Mem:/ { print $2 }')
    if [ "$MEM" -le 384 ]; then
        echo -e "${YELLOW}检测到小内存 ($MEM MB)，正在启用 Swap...${PLAIN}"
        if [ ! -f /swapfile ]; then
            dd if=/dev/zero of=/swapfile bs=1M count=512 status=none || true
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1 || true
            swapon /swapfile >/dev/null 2>&1 || true
            if ! grep -q "/swapfile" /etc/fstab; then
                echo "/swapfile none swap sw 0 0" >> /etc/fstab
            fi
        fi
    fi

    echo -e "${YELLOW}安装依赖...${PLAIN}"
    $PKG_CMD curl wget tar jq coreutils ca-certificates >/dev/null 2>&1
    [ "$OS" == "alpine" ] && apk add --no-cache libgcc bash grep >/dev/null 2>&1
}

# === 3. 安装软件 ===
install_bins() {
    mkdir -p $WORKDIR
    detect_arch

    if [ ! -f "$SB_BIN" ]; then
        echo -e "${YELLOW}下载 Sing-box...${PLAIN}"
        TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
        [ -z "$TAG" ] || [ "$TAG" = "null" ] && TAG="v1.8.0"
        VERSION=${TAG#v}
        URL="https://github.com/SagerNet/sing-box/releases/download/$TAG/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
        curl -L -o singbox.tar.gz "$URL"
        tar -xzf singbox.tar.gz -C $WORKDIR
        mv $WORKDIR/sing-box-*/sing-box $SB_BIN
        chmod +x $SB_BIN
        rm -rf singbox.tar.gz $WORKDIR/sing-box-* 
    fi

    if [ ! -f "$CF_BIN" ]; then
        echo -e "${YELLOW}下载 Cloudflared...${PLAIN}"
        curl -L -o $CF_BIN "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
        chmod +x $CF_BIN
    fi
}

# === 4. 生成配置 ===
config_singbox() {
    UUID=$(cat /proc/sys/kernel/random/uuid)
    cat > $CONFIG_FILE <<EOF
{
  "log": { "level": "error", "timestamp": true },
  "inbounds": [{
    "type": "vmess",
    "tag": "vmess-in",
    "listen": "127.0.0.1",
    "listen_port": $PORT,
    "users": [{ "uuid": "$UUID", "alterId": 0 }],
    "transport": { "type": "ws", "path": "/vmess" }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
}

# === 5. 设置服务 (动态协议) ===
setup_service() {
    MODE=$1
    TOKEN_OR_URL=$2
    PROTOCOL=$3

    if [ "$INIT" == "systemd" ]; then
        systemctl stop singbox_lite cloudflared_lite 2>/dev/null || true
    else
        rc-service singbox_lite stop 2>/dev/null || true
        rc-service cloudflared_lite stop 2>/dev/null || true
    fi

    # Systemd
    if [ "$INIT" == "systemd" ]; then
        cat > /etc/systemd/system/singbox_lite.service <<EOF
[Unit]
Description=Sing-box Lite
After=network.target
[Service]
Environment="GOGC=20"
ExecStart=$SB_BIN run -c $CONFIG_FILE
Restart=on-failure
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF

        if [ "$MODE" == "fixed" ]; then
            CF_EXEC="$CF_BIN tunnel run --protocol $PROTOCOL --token $TOKEN_OR_URL"
        else
            CF_EXEC="$CF_BIN tunnel --url http://localhost:$PORT --no-autoupdate --protocol $PROTOCOL"
        fi

        cat > /etc/systemd/system/cloudflared_lite.service <<EOF
[Unit]
Description=Cloudflared Lite
After=network.target singbox_lite.service
[Service]
Environment="GOGC=20"
ExecStart=$CF_EXEC
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable singbox_lite cloudflared_lite >/dev/null 2>&1
        systemctl restart singbox_lite cloudflared_lite

    # OpenRC (Alpine)
    elif [ "$INIT" == "openrc" ]; then
        cat > /etc/init.d/singbox_lite <<EOF
#!/sbin/openrc-run
description="Sing-box Lite"
command="$SB_BIN"
command_args="run -c $CONFIG_FILE"
command_background="yes"
pidfile="/run/singbox_lite.pid"
depend() { need net; }
start_pre() { export GOGC=20; }
EOF
        chmod +x /etc/init.d/singbox_lite

        if [ "$MODE" == "fixed" ]; then
            CF_ARGS="tunnel run --protocol $PROTOCOL --token $TOKEN_OR_URL"
        else
            CF_ARGS="tunnel --url http://localhost:$PORT --no-autoupdate --protocol $PROTOCOL"
        fi

        cat > /etc/init.d/cloudflared_lite <<EOF
#!/sbin/openrc-run
description="Cloudflared Lite"
command="$CF_BIN"
command_args="$CF_ARGS"
command_background="yes"
pidfile="/run/cloudflared_lite.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.err"
depend() { need net; after singbox_lite; }
start_pre() { 
    export GOGC=20
    echo "" > /var/log/cloudflared.log
    echo "" > /var/log/cloudflared.err
}
EOF
        chmod +x /etc/init.d/cloudflared_lite

        rc-update add singbox_lite default >/dev/null
        rc-update add cloudflared_lite default >/dev/null
        rc-service singbox_lite restart
        rc-service cloudflared_lite restart
    fi

    # 添加 Crontab
    if ! crontab -l 2>/dev/null | grep -q "cloudflared_lite"; then
        (crontab -l 2>/dev/null || true; echo "0 4 * * * /bin/sh -c 'rm -f /var/log/cloudflared.*; rc-service cloudflared_lite restart 2>/dev/null || systemctl restart cloudflared_lite 2>/dev/null'") | crontab - >/dev/null 2>&1 || true
    fi
}

# === 6. 获取临时域名 ===
get_temp_domain() {
    echo -e "${YELLOW}正在获取临时域名 (协议: $PROTOCOL, 等待5秒)...${PLAIN}"
    sleep 5
    
    DOMAIN=""
    for i in {1..10}; do
        if [ "$INIT" == "systemd" ]; then
            DOMAIN=$(journalctl -u cloudflared_lite --no-pager -n 50 | grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" | head -n 1 | sed 's/https:\/\///')
        else
            if [ -f "/var/log/cloudflared.err" ]; then
                DOMAIN=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" /var/log/cloudflared.err | head -n 1 | sed 's/https:\/\///')
            fi
            if [ -z "$DOMAIN" ] && [ -f "/var/log/cloudflared.log" ]; then
                DOMAIN=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" /var/log/cloudflared.log | head -n 1 | sed 's/https:\/\///')
            fi
        fi

        if [ -n "$DOMAIN" ]; then
            break
        fi
        sleep 2
    done

    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}获取失败! 请检查日志 /var/log/cloudflared.err${PLAIN}"
        exit 1
    fi
}

show_result() {
    echo ""
    echo "=================================================="
    echo -e "       ${GREEN}Sing-box + Argo ($PROTOCOL) 安装成功!${PLAIN}"
    echo "=================================================="
    echo -e "域名 (Address) : ${YELLOW}$DOMAIN${PLAIN}"
    echo -e "端口 (Port)    : ${YELLOW}443${PLAIN}"
    echo -e "UUID           : ${YELLOW}$UUID${PLAIN}"
    echo -e "协议 (Protocol): ${YELLOW}VMess + WS + TLS${PLAIN}"
    echo -e "路径 (Path)    : ${YELLOW}/vmess${PLAIN}"
    echo "=================================================="
    
    VMESS_JSON="{\"v\":\"2\",\"ps\":\"Argo-${PROTOCOL}-${DOMAIN}\",\"add\":\"$DOMAIN\",\"port\":\"443\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"/vmess\",\"tls\":\"tls\",\"sni\":\"$DOMAIN\"}"
    VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 | tr -d '\n')"
    
    echo -e "${GREEN}VMess 链接:${PLAIN}"
    echo "$VMESS_LINK"
    echo "=================================================="
    if [ "$MODE" == "temp" ]; then
        echo -e "${YELLOW}提示: 临时域名重启会变。如果连不上，请在 v2rayN 尝试:${PLAIN}"
        echo "1. 开启'跳过证书验证'"
        echo "2. 将地址改为优选IP (如 www.visa.com.hk)"
    fi
}

uninstall() {
    echo "正在卸载..."
    if [ "$INIT" == "systemd" ]; then
        systemctl stop singbox_lite cloudflared_lite 2>/dev/null || true
        systemctl disable singbox_lite cloudflared_lite 2>/dev/null || true
        rm -f /etc/systemd/system/singbox_lite.service /etc/systemd/system/cloudflared_lite.service
        systemctl daemon-reload
    else
        rc-service singbox_lite stop 2>/dev/null || true
        rc-service cloudflared_lite stop 2>/dev/null || true
        rc-update del singbox_lite default 2>/dev/null || true
        rc-update del cloudflared_lite default 2>/dev/null || true
        rm -f /etc/init.d/singbox_lite /etc/init.d/cloudflared_lite
    fi
    rm -rf $WORKDIR $SB_BIN $CF_BIN /var/log/cloudflared.*
    echo "卸载完成。"
}

# === 协议选择函数 (修复读取逻辑) ===
select_protocol() {
    echo "------------------------------------------------"
    echo -e "${YELLOW}请选择 Cloudflare 隧道协议:${PLAIN}"
    echo "1. HTTP2 (TCP) - 兼容性好，稳，但容易被阻断"
    echo "2. QUIC  (UDP) - 速度快，穿透强，但部分地区封UDP"
    echo "------------------------------------------------"
    # 关键修改： < /dev/tty 强制从终端读取用户输入，防止 curl 管道模式下跳过输入
    read -p "请选择协议 [1-2] (默认2 QUIC): " proto_choice < /dev/tty
    
    case "$proto_choice" in
        1*) PROTOCOL="http2" ;;
        *) PROTOCOL="quic" ;;
    esac
    echo -e "已选择协议: ${GREEN}$PROTOCOL${PLAIN}"
}

# === 菜单 ===
check_root
detect_system

clear
echo "------------------------------------------------"
echo -e "${GREEN} Sing-box + Argo 终极版 (V5.2 修复版) ${PLAIN}"
echo "------------------------------------------------"
echo "1. 固定隧道 (Token模式)"
echo "2. 临时隧道 (随机域名)"
echo "3. 卸载"
echo "0. 退出"
echo "------------------------------------------------"
# 关键修改： < /dev/tty
read -p "选择: " choice < /dev/tty

case "$choice" in
    1)
        select_protocol
        echo "请在 Cloudflare 后台将 Service 设置为: HTTP -> localhost:8001"
        read -p "输入 Token: " TOKEN < /dev/tty
        [ -z "$TOKEN" ] && exit 1
        read -p "输入域名: " DOMAIN < /dev/tty
        [ -z "$DOMAIN" ] && DOMAIN="fixed.com"
        MODE="fixed"
        optimize_env
        install_bins
        config_singbox
        setup_service "fixed" "$TOKEN" "$PROTOCOL"
        show_result
        ;;
    2)
        select_protocol
        MODE="temp"
        optimize_env
        install_bins
        config_singbox
        setup_service "temp" "" "$PROTOCOL"
        get_temp_domain
        show_result
        ;;
    3) uninstall ;;
    0) exit 0 ;;
    *) echo "无效";;
esac
