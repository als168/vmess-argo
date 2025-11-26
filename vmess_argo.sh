#!/bin/bash
# =========================================================
# Xray (VMess) + Argo 全能优化版 (128M 内存 / 256M 硬盘 专用)
# 功能: 自动 Swap / GOGC 内存压制 / 硬盘瘦身 / 双模式选择
# =========================================================

set -e

# === 全局配置 ===
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

# === 1. 环境检查与准备 ===
check_root() {
    [ "$(id -u)" != "0" ] && echo -e "${RED}请使用 root 运行!${PLAIN}" && exit 1
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
        x86_64)  X_ARCH="64"; C_ARCH="amd64" ;;
        aarch64) X_ARCH="arm64-v8a"; C_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
    esac
}

# === 2. 极限环境优化 (核心) ===
optimize_env() {
    # 1. 自动 Swap (128M 机器必须有)
    MEM=$(free -m | awk '/Mem:/ { print $2 }')
    if [ "$MEM" -le 384 ]; then
        echo -e "${YELLOW}检测到小内存 ($MEM MB)，正在启用 Swap 防崩溃保护...${PLAIN}"
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

    # 2. 安装基础依赖
    echo -e "${YELLOW}安装必要组件...${PLAIN}"
    $PKG_CMD curl wget unzip jq coreutils ca-certificates >/dev/null 2>&1
    [ "$OS" == "alpine" ] && apk add --no-cache libgcc >/dev/null 2>&1
}

# === 3. 安装软件 (硬盘优化) ===
install_bins() {
    mkdir -p $WORKDIR
    detect_arch

    # 安装 Xray
    if [ ! -f "$XRAY_BIN" ]; then
        echo -e "${YELLOW}下载 Xray...${PLAIN}"
        TAG=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
        [ -z "$TAG" ] || [ "$TAG" = "null" ] && TAG="v1.8.4"
        curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/$TAG/Xray-linux-$X_ARCH.zip"
        unzip -qo xray.zip -d $WORKDIR
        mv $WORKDIR/xray $XRAY_BIN
        chmod +x $XRAY_BIN
        
        # [优化重点] 删除 Geo 文件和 Zip 包，节省 60MB+ 硬盘
        echo -e "${YELLOW}执行硬盘瘦身...${PLAIN}"
        rm -f xray.zip $WORKDIR/geoip.dat $WORKDIR/geosite.dat $WORKDIR/*.md $WORKDIR/LICENSE
    fi

    # 安装 Cloudflared
    if [ ! -f "$CF_BIN" ]; then
        echo -e "${YELLOW}下载 Cloudflared...${PLAIN}"
        curl -L -o $CF_BIN "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$C_ARCH"
        chmod +x $CF_BIN
    fi
}

# === 4. 生成 Xray 配置 ===
config_xray() {
    UUID=$(cat /proc/sys/kernel/random/uuid)
    # 监听 127.0.0.1:8001，协议 WS (最省内存)
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

# === 5. 配置服务守护 (内存压制) ===
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

    # --- Systemd (Debian/Ubuntu/CentOS) ---
    if [ "$INIT" == "systemd" ]; then
        # Xray Service (带 GOGC=20 优化)
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

        # Cloudflared Service (带 GOGC=20 优化)
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

    # --- OpenRC (Alpine) ---
    elif [ "$INIT" == "openrc" ]; then
        # Xray Service
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

        # Cloudflared Service
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
    # 启动前清空日志，防止硬盘爆满
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

    # [优化重点] 添加每日自动维护任务 (重启释放内存 + 清理日志)
    # 每天凌晨 4 点执行
    if ! crontab -l 2>/dev/null | grep -q "cloudflared_opt"; then
        CMD_RESTART="rc-service cloudflared_opt restart || systemctl restart cloudflared_opt"
        (crontab -l 2>/dev/null; echo "0 4 * * * /bin/sh -c 'rm -f /var/log/cloudflared.*; $CMD_RESTART'") | crontab -
        echo -e "${YELLOW}已添加每日凌晨4点自动维护任务${PLAIN}"
    fi
}

# === 6. 获取临时域名 ===
get_temp_domain() {
    echo -e "${YELLOW}正在请求 Cloudflare 临时域名 (请等待 10 秒)...${PLAIN}"
    sleep 8
    if [ "$INIT" == "systemd" ]; then
        LOG_CMD="journalctl -u cloudflared_opt --no-pager -n 50"
    else
        LOG_CMD="cat /var/log/cloudflared.err /var/log/cloudflared.log 2>/dev/null"
    fi
    
    for i in {1..10}; do
        DOMAIN=$($LOG_CMD | grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" | head -n 1 | sed 's/https:\/\///')
        if [ -n "$DOMAIN" ]; then
            break
        fi
        sleep 2
    done
    
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}获取失败，请检查网络或稍后重试。${PLAIN}"
        exit 1
    fi
}

# === 7. 展示结果 ===
show_result() {
    echo ""
    echo "=================================================="
    echo -e "         ${GREEN}Xray + Argo 优化版 安装成功${PLAIN}"
    echo "=================================================="
    echo -e "地址 (Domain)  : ${YELLOW}$DOMAIN${PLAIN}"
    echo -e "端口 (Port)    : ${YELLOW}443${PLAIN}"
    echo -e "UUID           : ${YELLOW}$UUID${PLAIN}"
    echo -e "协议 (Protocol): ${YELLOW}VMess + WS + TLS${PLAIN}"
    echo -e "路径 (Path)    : ${YELLOW}/vmess${PLAIN}"
    echo "--------------------------------------------------"
    
    VMESS_JSON="{\"v\":\"2\",\"ps\":\"Argo-${DOMAIN}\",\"add\":\"$DOMAIN\",\"port\":\"443\",\"id\":\"$UUID\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"/vmess\",\"tls\":\"tls\",\"sni\":\"$DOMAIN\"}"
    VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 | tr -d '\n')"
    
    echo -e "${GREEN}VMess 链接:${PLAIN}"
    echo "$VMESS_LINK"
    echo "=================================================="
    if [ "$MODE" == "fixed" ]; then
        echo -e "${RED}重要提示:${PLAIN} 请确保在 Cloudflare Tunnel 后台设置:"
        echo -e "Service: ${GREEN}HTTP${PLAIN}  ->  URL: ${GREEN}localhost:8001${PLAIN}"
    else
        echo -e "${YELLOW}提示: 临时域名重启后会改变，请知悉。${PLAIN}"
    fi
}

uninstall() {
    echo -e "${YELLOW}正在卸载...${PLAIN}"
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
    rm -rf $WORKDIR $XRAY_BIN $CF_BIN /var/log/cloudflared.*
    echo -e "${GREEN}卸载完成，系统已清理。${PLAIN}"
}

# === 主菜单 ===
check_root
detect_system

clear
echo "------------------------------------------------"
echo -e "${GREEN} Xray + Argo 极限优化脚本 (128MB内存专用) ${PLAIN}"
echo "------------------------------------------------"
echo "1. 固定隧道 (需要 Token，长期稳定，推荐)"
echo "2. 临时隧道 (无需 Token，随机域名，测试用)"
echo "3. 卸载服务"
echo "0. 退出"
echo "------------------------------------------------"
read -p "请选择 [0-3]: " choice

case "$choice" in
    1)
        echo "------------------------------------------------"
        echo -e "${YELLOW}前置准备:${PLAIN}"
        echo "请去 Cloudflare Zero Trust -> Access -> Tunnels"
        echo "设置 Public Hostname: Service -> HTTP -> localhost:8001"
        echo "------------------------------------------------"
        read -p "请输入 Cloudflare Tunnel Token: " TOKEN
        [ -z "$TOKEN" ] && echo "Token 不能为空" && exit 1
        read -p "请输入绑定的域名 (仅用于显示): " DOMAIN
        [ -z "$DOMAIN" ] && DOMAIN="fixed-domain.com"
        
        MODE="fixed"
        optimize_env
        install_bins
        config_xray
        setup_service "fixed" "$TOKEN"
        show_result
        ;;
    2)
        echo "------------------------------------------------"
        echo -e "${YELLOW}正在配置临时隧道 (TryCloudflare)...${PLAIN}"
        echo "------------------------------------------------"
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
