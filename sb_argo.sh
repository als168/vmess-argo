#!/bin/bash
# =========================================================
# Sing-box + Argo 全能脚本 (128M 内存极限优化版)
# 核心替换为 Sing-box，内存占用更低
# =========================================================

set -e

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

# === 1. 环境准备 (修复版) ===
check_root() {
    # 使用 if 语句代替 && 简写，防止 set -e 误判退出
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
    # 自动 Swap
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

    # 安装依赖
    echo -e "${YELLOW}安装依赖...${PLAIN}"
    $PKG_CMD curl wget tar jq coreutils ca-certificates >/dev/null 2>&1
    [ "$OS" == "alpine" ] && apk add --no-cache libgcc >/dev/null 2>&1
}

# === 3. 安装 Sing-box 和 Cloudflared ===
install_bins() {
    mkdir -p $WORKDIR
    detect_arch

    # 安装 Sing-box
    if [ ! -f "$SB_BIN" ]; then
        echo -e "${YELLOW}下载 Sing-box...${PLAIN}"
        # 获取最新版本
        TAG=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
        [ -z "$TAG" ] || [ "$TAG" = "null" ] && TAG="v1.8.0"
        
        # Sing-box 官方包名规则: sing-box-1.8.0-linux-amd64.tar.gz
        VERSION=${TAG#v}
        URL="https://github.com/SagerNet/sing-box/releases/download/$TAG/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
        
        curl -L -o singbox.tar.gz "$URL"
        tar -xzf singbox.tar.gz -C $WORKDIR
        # 提取二进制文件 (解压出来的目录带版本号，需要通配符)
        mv $WORKDIR/sing-box-*/sing-box $SB_BIN
        chmod +x $SB_BIN
        # 清理
        rm -rf singbox.tar.gz $WORKDIR/sing-box-* 
    fi

    # 安装 Cloudflared
    if [ ! -f "$CF_BIN" ]; then
        echo -e "${YELLOW}下载 Cloudflared...${PLAIN}"
        curl -L -o $CF_BIN "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
        chmod +x $CF_BIN
    fi
}

# === 4. 生成 Sing-box 配置 (JSON) ===
config_singbox() {
    UUID=$(cat /proc/sys/kernel/random/uuid)
    
    # Sing-box 的配置比 Xray 更简洁
    cat > $CONFIG_FILE <<EOF
{
  "log": {
    "level": "error",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vmess"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
}

# === 5. 设置服务 (GOGC优化) ===
setup_service() {
    MODE=$1
    TOKEN_OR_URL=$2

    # 停止旧服务
    if [ "$INIT" == "systemd" ]; then
        systemctl stop singbox_lite cloudflared_lite 2>/dev/null || true
    else
        rc-service singbox_lite stop 2>/dev/null || true
        rc-service cloudflared_lite stop 2>/dev/null || true
    fi

    # 重点：Environment="GOGC=20" 压制 Sing-box 内存
    
    if [ "$INIT" == "systemd" ]; then
        # Sing-box Service
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

        # Cloudflared Service
        if [ "$MODE" == "fixed" ]; then
            CF_EXEC="$CF_BIN tunnel run --token $TOKEN_OR_URL"
        else
            CF_EXEC="$CF_BIN tunnel --url http://localhost:$PORT --no-autoupdate --protocol http2"
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

    elif [ "$INIT" == "openrc" ]; then
        # Sing-box Service (OpenRC)
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

        # Cloudflared Service (OpenRC)
        if [ "$MODE" == "fixed" ]; then
            CF_ARGS="tunnel run --token $TOKEN_OR_URL"
        else
            CF_ARGS="tunnel --url http://localhost:$PORT --no-autoupdate --protocol http2"
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

    # 添加定时清理任务
    if ! crontab -l 2>/dev/null | grep -q "cloudflared_lite"; then
        (crontab -l 2>/dev/null; echo "0 4 * * * /bin/sh -c 'rm -f /var/log/cloudflared.*; rc-service cloudflared_lite restart || systemctl restart cloudflared_lite'") | crontab -
    fi
}

get_temp_domain() {
    echo -e "${YELLOW}获取临时域名...${PLAIN}"
    sleep 5
    if [ "$INIT" == "systemd" ]; then
        LOG_CMD="journalctl -u cloudflared_lite --no-pager -n 50"
    else
        LOG_CMD="cat /var/log/cloudflared.err /var/log/cloudflared.log 2>/dev/null"
    fi
    for i in {1..10}; do
        DOMAIN=$($LOG_CMD | grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" | head -n 1 | sed 's/https:\/\///')
        [ -n "$DOMAIN" ] && break
        sleep 3
    done
    [ -z "$DOMAIN" ] && echo -e "${RED}获取失败${PLAIN}" && exit 1
}

show_result() {
    echo ""
    echo "=================================================="
    echo -e "       ${GREEN}Sing-box + Argo 安装成功!${PLAIN}"
    echo "=================================================="
    echo -e "域名 (Address) : ${YELLOW}$DOMAIN${PLAIN}"
    echo -e "端口 (Port)    : ${YELLOW}443${PLAIN}"
    echo -e "UUID           : ${YELLOW}$UUID${PLAIN}"
    echo -e "核心 (Core)    : ${YELLOW}Sing-box${PLAIN}"
    echo -e "路径 (Path)    : ${YELLOW}/vmess${PLAIN}"
    echo "=================================================="
    
    VMESS_JSON="{\"v\":\"2\",\"ps\":\"Sb-Argo-${DOMAIN}\",\"add\":\"$DOMAIN\",\"port\":\"443\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"/vmess\",\"tls\":\"tls\",\"sni\":\"$DOMAIN\"}"
    VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 | tr -d '\n')"
    
    echo -e "${GREEN}VMess 链接:${PLAIN}"
    echo "$VMESS_LINK"
    echo "=================================================="
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

# === 菜单 ===
check_root
detect_system

clear
echo "------------------------------------------------"
echo -e "${GREEN} Sing-box + Argo 全能脚本 (128M优化版) ${PLAIN}"
echo "------------------------------------------------"
echo "1. 固定隧道 (Token模式, 长期推荐)"
echo "2. 临时隧道 (无Token, 测试用)"
echo "3. 卸载"
echo "0. 退出"
echo "------------------------------------------------"
read -p "选择: " choice

case "$choice" in
    1)
        echo "请在 Cloudflare 后台将 Service 设置为: HTTP -> localhost:8001"
        read -p "输入 Token: " TOKEN
        [ -z "$TOKEN" ] && exit 1
        read -p "输入域名: " DOMAIN
        [ -z "$DOMAIN" ] && DOMAIN="fixed.com"
        MODE="fixed"
        optimize_env
        install_bins
        config_singbox
        setup_service "fixed" "$TOKEN"
        show_result
        ;;
    2)
        MODE="temp"
        optimize_env
        install_bins
        config_singbox
        setup_service "temp" ""
        get_temp_domain
        show_result
        ;;
    3) uninstall ;;
    0) exit 0 ;;
    *) echo "无效";;
esac
