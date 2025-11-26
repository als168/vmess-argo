#!/bin/bash
# =========================================================
# Xray (VMess) + Argo 终极修复版 (V7.0)
# 1. 自动识别 AMD64/ARM64 架构
# 2. 增加下载文件校验，防止安装失败
# 3. 修复 curl 管道模式下的输入问题
# 4. 完美适配 128MB 小内存 (Swap + GOGC)
# =========================================================

# === 变量 ===
PORT=8001
WORKDIR="/etc/xray_optimized"
CONFIG_FILE="$WORKDIR/config.json"
XRAY_BIN="/usr/local/bin/xray"
CF_BIN="/usr/local/bin/cloudflared"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# === 1. 环境检查 ===
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

# 自动识别架构 (关键修复)
detect_arch() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  
            X_ARCH="64"
            C_ARCH="amd64"
            ;;
        aarch64) 
            X_ARCH="arm64-v8a"
            C_ARCH="arm64"
            ;;
        *) 
            echo -e "${RED}不支持的架构: $ARCH${PLAIN}"
            exit 1 
            ;;
    esac
    echo -e "${GREEN}检测到架构: $ARCH${PLAIN}"
}

# === 2. 优化与依赖 ===
optimize_env() {
    # 自动 Swap
    MEM=$(free -m | awk '/Mem:/ { print $2 }')
    if [ "$MEM" -le 384 ]; then
        echo -e "${YELLOW}检测到小内存 ($MEM MB)，启用 Swap...${PLAIN}"
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

    # 强制安装 unzip (修复解压失败)
    echo -e "${YELLOW}安装依赖...${PLAIN}"
    $PKG_CMD curl wget unzip jq coreutils ca-certificates >/dev/null 2>&1
    [ "$OS" == "alpine" ] && apk add --no-cache libgcc bash grep >/dev/null 2>&1
}

# === 3. 安装软件 (强力模式) ===
install_bins() {
    mkdir -p $WORKDIR
    detect_arch

    # --- 安装 Xray ---
    if [ ! -f "$XRAY_BIN" ]; then
        echo -e "${YELLOW}正在下载 Xray (v1.8.4)...${PLAIN}"
        # 强制使用 v1.8.4 稳定版，防止 API 获取失败
        URL="https://github.com/XTLS/Xray-core/releases/download/v1.8.4/Xray-linux-$X_ARCH.zip"
        
        wget -O xray.zip "$URL"
        
        if [ ! -f "xray.zip" ]; then
            echo -e "${RED}Xray 下载失败，请检查网络!${PLAIN}"
            exit 1
        fi

        unzip -o xray.zip -d $WORKDIR
        
        # 移动并赋权
        if [ -f "$WORKDIR/xray" ]; then
            mv "$WORKDIR/xray" $XRAY_BIN
            chmod +x $XRAY_BIN
        else
            echo -e "${RED}解压失败，未找到 binary 文件!${PLAIN}"
            exit 1
        fi
        
        # 瘦身
        rm -f xray.zip $WORKDIR/geoip.dat $WORKDIR/geosite.dat $WORKDIR/*.md $WORKDIR/LICENSE
        echo -e "${GREEN}Xray 安装完成!${PLAIN}"
    fi

    # --- 安装 Cloudflared ---
    if [ ! -f "$CF_BIN" ]; then
        echo -e "${YELLOW}正在下载 Cloudflared...${PLAIN}"
        curl -L -o $CF_BIN "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$C_ARCH"
        chmod +x $CF_BIN
        
        if [ ! -f "$CF_BIN" ]; then
            echo -e "${RED}Cloudflared 下载失败!${PLAIN}"
            exit 1
        fi
    fi
}

# === 4. 生成配置 ===
config_xray() {
    UUID=$(cat /proc/sys/kernel/random/uuid)
    cat > $CONFIG_FILE <<EOF
{
  "log": { "loglevel": "error", "access": "none" },
  "inbounds": [{
    "port": $PORT,
    "listen": "127.0.0.1",
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$UUID" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess" } }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
}

# === 5. 设置服务 (内存优化) ===
setup_service() {
    MODE=$1
    TOKEN_OR_URL=$2

    # 停止旧服务
    if [ "$INIT" == "systemd" ]; then
        systemctl stop xray_opt cloudflared_opt 2>/dev/null || true
    else
        rc-service xray_opt stop 2>/dev/null || true
        rc-service cloudflared_opt stop 2>/dev/null || true
    fi

    # Systemd
    if [ "$INIT" == "systemd" ]; then
        cat > /etc/systemd/system/xray_opt.service <<EOF
[Unit]
Description=Xray Optimized
After=network.target
[Service]
Environment="GOGC=20"
ExecStart=$XRAY_BIN -c $CONFIG_FILE
Restart=on-failure
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF

        if [ "$MODE" == "fixed" ]; then
            CF_EXEC="$CF_BIN tunnel run --token $TOKEN_OR_URL"
        else
            CF_EXEC="$CF_BIN tunnel --url http://localhost:$PORT --no-autoupdate --protocol http2"
        fi

        cat > /etc/systemd/system/cloudflared_opt.service <<EOF
[Unit]
Description=Cloudflared Optimized
After=network.target xray_opt.service
[Service]
Environment="GOGC=20"
ExecStart=$CF_EXEC
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray_opt cloudflared_opt >/dev/null 2>&1
        systemctl restart xray_opt cloudflared_opt

    # OpenRC (Alpine)
    elif [ "$INIT" == "openrc" ]; then
        cat > /etc/init.d/xray_opt <<EOF
#!/sbin/openrc-run
description="Xray Optimized"
command="$XRAY_BIN"
command_args="-c $CONFIG_FILE"
command_background="yes"
pidfile="/run/xray_opt.pid"
depend() { need net; }
start_pre() { export GOGC=20; }
EOF
        chmod +x /etc/init.d/xray_opt

        if [ "$MODE" == "fixed" ]; then
            CF_ARGS="tunnel run --token $TOKEN_OR_URL"
        else
            CF_ARGS="tunnel --url http://localhost:$PORT --no-autoupdate --protocol http2"
        fi

        cat > /etc/init.d/cloudflared_opt <<EOF
#!/sbin/openrc-run
description="Cloudflared Optimized"
command="$CF_BIN"
command_args="$CF_ARGS"
command_background="yes"
pidfile="/run/cloudflared_opt.pid"
output_log="/var/log/cloudflared.log"
error_log="/var/log/cloudflared.err"
depend() { need net; after xray_opt; }
start_pre() {
    export GOGC=20
    echo "" > /var/log/cloudflared.log
    echo "" > /var/log/cloudflared.err
}
EOF
        chmod +x /etc/init.d/cloudflared_opt

        rc-update add xray_opt default >/dev/null
        rc-update add cloudflared_opt default >/dev/null
        rc-service xray_opt restart
        rc-service cloudflared_opt restart
    fi

    # Crontab 自动清理
    if ! crontab -l 2>/dev/null | grep -q "cloudflared_opt"; then
        (crontab -l 2>/dev/null || true; echo "0 4 * * * /bin/sh -c 'rm -f /var/log/cloudflared.*; rc-service cloudflared_opt restart 2>/dev/null || systemctl restart cloudflared_opt 2>/dev/null'") | crontab - >/dev/null 2>&1 || true
    fi
}

# === 6. 获取临时域名 ===
get_temp_domain() {
    echo -e "${YELLOW}正在请求 Cloudflare 临时域名 (请等待 10 秒)...${PLAIN}"
    sleep 8
    DOMAIN=""
    for i in {1..10}; do
        if [ "$INIT" == "systemd" ]; then
            DOMAIN=$(journalctl -u cloudflared_opt --no-pager -n 50 | grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" | head -n 1 | sed 's/https:\/\///')
        else
            if [ -f "/var/log/cloudflared.err" ]; then
                DOMAIN=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" /var/log/cloudflared.err | head -n 1 | sed 's/https:\/\///')
            fi
            if [ -z "$DOMAIN" ] && [ -f "/var/log/cloudflared.log" ]; then
                DOMAIN=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" /var/log/cloudflared.log | head -n 1 | sed 's/https:\/\///')
            fi
        fi
        if [ -n "$DOMAIN" ]; then break; fi
        sleep 2
    done
    
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}获取失败，请检查日志 /var/log/cloudflared.err${PLAIN}"
        exit 1
    fi
}

# === 7. 展示结果 ===
show_result() {
    echo ""
    echo "=================================================="
    echo -e "       ${GREEN}Xray + Argo V7.0 安装成功!${PLAIN}"
    echo "=================================================="
    echo -e "地址 (Domain)  : ${YELLOW}$DOMAIN${PLAIN}"
    echo -e "端口 (Port)    : ${YELLOW}443${PLAIN}"
    echo -e "UUID           : ${YELLOW}$UUID${PLAIN}"
    echo -e "协议 (Protocol): ${YELLOW}VMess + WS + TLS${PLAIN}"
    echo -e "路径 (Path)    : ${YELLOW}/vmess${PLAIN}"
    echo "=================================================="
    
    VMESS_JSON="{\"v\":\"2\",\"ps\":\"Argo-${DOMAIN}\",\"add\":\"$DOMAIN\",\"port\":\"443\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"/vmess\",\"tls\":\"tls\",\"sni\":\"$DOMAIN\"}"
    VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 | tr -d '\n')"
    
    echo -e "${GREEN}VMess 链接:${PLAIN}"
    echo "$VMESS_LINK"
    echo "=================================================="
    if [ "$MODE" == "fixed" ]; then
        echo -e "${RED}重要提示:${PLAIN} 请确保在 Cloudflare Tunnel 后台设置:"
        echo -e "Service: ${GREEN}HTTP${PLAIN}  ->  URL: ${GREEN}localhost:8001${PLAIN}"
    else
        echo -e "${YELLOW}提示: 临时域名重启后会改变，且容易被墙。${PLAIN}"
    fi
}

# === 8. 卸载功能 ===
uninstall() {
    echo -e "${YELLOW}正在卸载 Xray + Argo...${PLAIN}"
    
    if [ "$INIT" == "systemd" ]; then
        systemctl stop xray_opt cloudflared_opt 2>/dev/null || true
        systemctl disable xray_opt cloudflared_opt 2>/dev/null || true
        rm -f /etc/systemd/system/xray_opt.service /etc/systemd/system/cloudflared_opt.service
        systemctl daemon-reload
    else
        rc-service xray_opt stop 2>/dev/null || true
        rc-service cloudflared_opt stop 2>/dev/null || true
        rc-update del xray_opt default 2>/dev/null || true
        rc-update del cloudflared_opt default 2>/dev/null || true
        rm -f /etc/init.d/xray_opt /etc/init.d/cloudflared_opt
    fi
    
    killall -9 xray cloudflared 2>/dev/null || true
    rm -rf "$WORKDIR" "$XRAY_BIN" "$CF_BIN" /var/log/cloudflared.*
    
    crontab -l 2>/dev/null | grep -v "cloudflared_opt" | crontab -
    
    echo -e "${GREEN}卸载完成，系统已恢复纯净。${PLAIN}"
}

# === 主菜单 ===
check_root
detect_system

clear
echo "------------------------------------------------"
echo -e "${GREEN} Xray + Argo 终极修复版 (V7.0) ${PLAIN}"
echo -e "${YELLOW} 自动识别架构 | 强力安装模式 | 内存优化 ${PLAIN}"
echo "------------------------------------------------"
echo "1. 固定隧道 (Token模式, 长期推荐)"
echo "2. 临时隧道 (随机域名, 临时测试)"
echo "3. 卸载服务"
echo "0. 退出"
echo "------------------------------------------------"
# 修复 curl 管道输入问题
read -p "请选择 [0-3]: " choice < /dev/tty

case "$choice" in
    1)
        read -p "请输入 Cloudflare Tunnel Token: " TOKEN < /dev/tty
        [ -z "$TOKEN" ] && echo "Token 不能为空" && exit 1
        read -p "请输入绑定的域名: " DOMAIN < /dev/tty
        [ -z "$DOMAIN" ] && DOMAIN="fixed-domain.com"
        
        MODE="fixed"
        optimize_env
        install_bins
        config_xray
        setup_service "fixed" "$TOKEN"
        show_result
        ;;
    2)
        MODE="temp"
        optimize_env
        install_bins
        config_xray
        setup_service "temp" ""
        get_temp_domain
        show_result
        ;;
    3) uninstall ;;
    0) exit 0 ;;
    *) echo "无效选项" ;;
esac
