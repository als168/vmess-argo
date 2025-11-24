#!/bin/bash
set -e

WORK_DIR="/etc/xray"
CONFIG_FILE="$WORK_DIR/config.json"
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
XRAY_PORT=8001
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

write_xray_config() {
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

write_cloudflared_config() {
  read -p "请输入你的隧道ID: " TUNNEL_ID
  read -p "请输入你在 Cloudflare 控制台绑定的域名: " ARGO_DOMAIN
  mkdir -p /etc/cloudflared
  cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$XRAY_PORT
    originRequest:
      httpHostHeader: $ARGO_DOMAIN
  - service: http_status:404
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

  vmess_json=$(cat <<EOF
{
  "v": "2",
  "ps": "Argo-Vmess",
  "add": "$ARGO_DOMAIN",
  "port": "443",
  "id": "$UUID",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "$ARGO_DOMAIN",
  "path": "$WS_PATH",
  "tls": "tls"
}
EOF
)
  vmess_link="vmess://$(echo -n "$vmess_json" | base64 -w0)"
  echo "V2RayN 链接: $vmess_link"
}

uninstall_all() {
  echo "[WARN] 正在卸载 Xray + Cloudflared..."
  killall xray 2>/dev/null || true
  killall cloudflared 2>/dev/null || true
  rm -rf $WORK_DIR
  rm -f /usr/local/bin/xray
  rm -f /usr/local/bin/cloudflared
  rm -f /etc/cloudflared/config.yml
  rm -f /tmp/argo.log
  echo "[INFO] 卸载完成！"
}

menu() {
  echo "===== VMess + Argo ====="
  echo "1. 安装并启动 (临时隧道)"
  echo "2. 安装并启动 (自建隧道)"
  echo "3. 卸载"
  echo "0. 退出"
  read -p "请选择操作: " choice
  case "$choice" in
    1) install_xray; install_cloudflared; write_xray_config; start_xray; start_quick_tunnel; print_config ;;
    2) install_xray; install_cloudflared; write_xray_config; write_cloudflared_config; start_xray; start_named_tunnel; print_config ;;
    3) uninstall_all ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
  esac
}

menu
