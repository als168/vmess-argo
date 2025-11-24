#!/bin/bash
set -e

WORK_DIR="/etc/xray"
CONFIG_FILE="$WORK_DIR/config.json"
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
XRAY_PORT=10080
WS_PATH="/vmess"
ARGO_DOMAIN=""

install_xray() {
  mkdir -p $WORK_DIR
  arch=$(uname -m)
  case "$arch" in
    x86_64) dl_arch="64" ;;
    aarch64) dl_arch="arm64-v8a" ;;
    *) dl_arch="64" ;;
  esac
  curl -fsSL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$dl_arch.zip" -o xray.zip
  unzip -qo xray.zip -d $WORK_DIR && rm xray.zip
  install -m 755 $WORK_DIR/xray /usr/local/bin/xray
}

install_cloudflared() {
  arch=$(uname -m)
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  [ "$arch" = "aarch64" ] && url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
  curl -fsSL "$url" -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
}

write_config() {
  cat > $CONFIG_FILE <<EOF
{
  "inbounds": [{
    "port": $XRAY_PORT,
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$UUID" }] },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "$WS_PATH" }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
}

start_xray() {
  nohup xray -c $CONFIG_FILE >/dev/null 2>&1 &
}

start_quick_tunnel() {
  nohup cloudflared tunnel --url "http://localhost:$XRAY_PORT" --protocol http2 --no-autoupdate >/tmp/argo.log 2>&1 &
  sleep 5
  ARGO_DOMAIN=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/argo.log | tail -n1)
  ARGO_DOMAIN="${ARGO_DOMAIN#https://}"
}

start_named_tunnel() {
  read -p "请输入你的 Argo 隧道 token: " ARGO_TOKEN
  nohup cloudflared tunnel run --token "$ARGO_TOKEN" >/tmp/argo.log 2>&1 &
  sleep 5
  # 自建隧道需要你在 Cloudflare 控制台绑定域名，这里直接提示
  echo "[INFO] 请在 Cloudflare 控制台确认域名绑定"
}

print_config() {
  echo "===== 客户端配置 ====="
  echo "地址: $ARGO_DOMAIN"
  echo "端口: 443"
  echo "UUID: $UUID"
  echo "路径: $WS_PATH"
  echo "TLS: 开启"
  echo "Host/SNI: $ARGO_DOMAIN"
  echo "======================"
}

menu() {
  echo "===== VMess + Argo ====="
  echo "1. 安装并启动 (临时隧道)"
  echo "2. 安装并启动 (自建隧道)"
  echo "0. 退出"
  read -p "请选择操作: " choice
  case "$choice" in
    1) install_xray; install_cloudflared; write_config; start_xray; start_quick_tunnel; print_config ;;
    2) install_xray; install_cloudflared; write_config; start_xray; start_named_tunnel; print_config ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
  esac
}

menu
